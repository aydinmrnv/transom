//! The window model: the platform-independent heart of "the client is the real
//! window manager."
//!
//! It consumes the control stream (`ServerMessage`) and maintains the set of live
//! windows, each with its **source rect** — the sub-rectangle of the shared VDS
//! texture that this window occupies (protocol.md §2). The platform layer
//! (Windows: `win::app`) turns the emitted `ModelEvent`s into real native
//! windows, swapchain resizes, and crop rectangles, but owns none of this
//! bookkeeping. Keeping it here means it compiles and is unit-tested on any host.
//!
//! Invariants honoured:
//!  * Rects are VDS physical pixels, `u32` (I-2/I-3). No scaling, ever, lives here.
//!  * The host reports **actual** geometry (I-4); the model just stores what it is
//!    told and never assumes a requested size took effect.

use crate::wire::{Rect, ServerMessage, Size, WindowKind};

/// One managed window. `source` is its crop in the shared texture; its `w`/`h`
/// are also exactly the pixel size the native proxy window's client area must be,
/// because we blit 1:1 (invariants I-1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Window {
    pub id: u64,
    pub source: Rect,
    pub title: String,
    pub kind: WindowKind,
}

/// A high-level change the platform layer must react to. Derived from the raw
/// protocol so the platform code never touches JSON or message discriminators.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelEvent {
    /// The session (re)synced: the host sent `hello`. Everything before is stale;
    /// the platform layer should expect a fresh set of `WindowAdded`s and tear
    /// down any proxy window whose id does not reappear (see `Resynced`).
    Connected {
        vds: Size,
    },
    /// A new window: create a proxy sized to `source.w × source.h`.
    WindowAdded(Window),
    /// The window's source rect changed. If `size_changed`, the proxy's swapchain
    /// must be resized to the new `w × h` (I-4: this is the ACTUAL size).
    WindowRectChanged {
        id: u64,
        source: Rect,
        size_changed: bool,
    },
    WindowTitleChanged {
        id: u64,
        title: String,
    },
    /// The Mac raised this window; reflect focus in the proxy set.
    WindowFocused {
        id: u64,
    },
    /// The window is gone: destroy its proxy.
    WindowRemoved {
        id: u64,
    },
    /// After a `tileLayout` resync, these proxy ids were not in the layout and
    /// have been dropped from the model. Emitted so a reconnecting client can
    /// prune proxies that died while it was away.
    Resynced {
        removed: Vec<u64>,
    },
    /// The host sent an `error`. Surfaced for logging; not fatal on its own.
    HostError {
        code: u32,
        message: String,
    },
}

/// The live window set plus session state. Ordered by insertion so proxy
/// stacking / Alt-Tab order is stable and debuggable.
#[derive(Debug, Default)]
pub struct WindowModel {
    vds: Option<Size>,
    windows: Vec<Window>,
    focused: Option<u64>,
}

impl WindowModel {
    pub fn new() -> Self {
        WindowModel::default()
    }

    // Read accessors used by the runner, tests, and future UI. On a Windows-only
    // build the consumer keeps its own view from `ModelEvent`s, so these read as
    // unused there.
    #[allow(dead_code)]
    pub fn vds(&self) -> Option<Size> {
        self.vds
    }

    #[allow(dead_code)]
    pub fn focused(&self) -> Option<u64> {
        self.focused
    }

    #[allow(dead_code)]
    pub fn windows(&self) -> &[Window] {
        &self.windows
    }

    #[allow(dead_code)]
    pub fn get(&self, id: u64) -> Option<&Window> {
        self.windows.iter().find(|w| w.id == id)
    }

    fn index_of(&self, id: u64) -> Option<usize> {
        self.windows.iter().position(|w| w.id == id)
    }

    /// Fold one server message into the model, returning the events the platform
    /// layer must act on. A single message can yield several events (a resync
    /// removes a batch of stale windows).
    pub fn apply(&mut self, msg: ServerMessage) -> Vec<ModelEvent> {
        match msg {
            ServerMessage::Hello { vds, .. } => {
                self.vds = Some(vds);
                vec![ModelEvent::Connected { vds }]
            }
            ServerMessage::WindowCreated {
                id,
                rect,
                title,
                kind,
            } => {
                let window = Window {
                    id,
                    source: rect,
                    title,
                    kind,
                };
                // A create for an id we already track is treated as an update, so a
                // duplicate resync `windowCreated` is idempotent rather than a
                // second proxy.
                if let Some(i) = self.index_of(id) {
                    let size_changed =
                        self.windows[i].source.w != rect.w || self.windows[i].source.h != rect.h;
                    self.windows[i] = window;
                    vec![ModelEvent::WindowRectChanged {
                        id,
                        source: rect,
                        size_changed,
                    }]
                } else {
                    self.windows.push(window.clone());
                    vec![ModelEvent::WindowAdded(window)]
                }
            }
            ServerMessage::WindowMoved { id, rect } => {
                if let Some(i) = self.index_of(id) {
                    let size_changed =
                        self.windows[i].source.w != rect.w || self.windows[i].source.h != rect.h;
                    self.windows[i].source = rect;
                    vec![ModelEvent::WindowRectChanged {
                        id,
                        source: rect,
                        size_changed,
                    }]
                } else {
                    // A move for an unknown window: ignore rather than invent one,
                    // since we have no title/kind. The next resync will reconcile.
                    Vec::new()
                }
            }
            ServerMessage::WindowTitle { id, title } => {
                if let Some(i) = self.index_of(id) {
                    self.windows[i].title = title.clone();
                    vec![ModelEvent::WindowTitleChanged { id, title }]
                } else {
                    Vec::new()
                }
            }
            ServerMessage::WindowFocused { id } => {
                self.focused = Some(id);
                vec![ModelEvent::WindowFocused { id }]
            }
            ServerMessage::WindowDestroyed { id } => {
                if let Some(i) = self.index_of(id) {
                    self.windows.remove(i);
                    if self.focused == Some(id) {
                        self.focused = None;
                    }
                    vec![ModelEvent::WindowRemoved { id }]
                } else {
                    Vec::new()
                }
            }
            ServerMessage::TileLayout { windows, display } => {
                self.vds = Some(display);
                let mut events = Vec::new();
                // Update or add each window in the layout.
                for tw in &windows {
                    if let Some(i) = self.index_of(tw.id) {
                        let size_changed = self.windows[i].source.w != tw.rect.w
                            || self.windows[i].source.h != tw.rect.h;
                        if self.windows[i].source != tw.rect {
                            self.windows[i].source = tw.rect;
                            events.push(ModelEvent::WindowRectChanged {
                                id: tw.id,
                                source: tw.rect,
                                size_changed,
                            });
                        }
                    } else {
                        // The layout carries no title/kind; a bare tile entry for an
                        // unseen id becomes a titleless normal window until a
                        // `windowCreated`/`windowTitle` fills it in.
                        let window = Window {
                            id: tw.id,
                            source: tw.rect,
                            title: String::new(),
                            kind: WindowKind::Normal,
                        };
                        self.windows.push(window.clone());
                        events.push(ModelEvent::WindowAdded(window));
                    }
                }
                // Drop any window not present in the layout (it died while we were
                // away, or the host reorganized). Prune and report.
                let live: Vec<u64> = windows.iter().map(|w| w.id).collect();
                let mut removed = Vec::new();
                self.windows.retain(|w| {
                    if live.contains(&w.id) {
                        true
                    } else {
                        removed.push(w.id);
                        false
                    }
                });
                if let Some(f) = self.focused {
                    if !live.contains(&f) {
                        self.focused = None;
                    }
                }
                if !removed.is_empty() {
                    events.push(ModelEvent::Resynced { removed });
                }
                events
            }
            ServerMessage::Error { code, message } => {
                vec![ModelEvent::HostError { code, message }]
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::TileWindow;

    fn rect(x: u32, y: u32, w: u32, h: u32) -> Rect {
        Rect { x, y, w, h }
    }

    fn created(id: u64, r: Rect, title: &str) -> ServerMessage {
        ServerMessage::WindowCreated {
            id,
            rect: r,
            title: title.to_string(),
            kind: WindowKind::Normal,
        }
    }

    #[test]
    fn hello_sets_vds_and_connects() {
        let mut m = WindowModel::new();
        let ev = m.apply(ServerMessage::Hello {
            protocol: 1,
            vds: Size { w: 5120, h: 2880 },
        });
        assert_eq!(
            ev,
            vec![ModelEvent::Connected {
                vds: Size { w: 5120, h: 2880 }
            }]
        );
        assert_eq!(m.vds(), Some(Size { w: 5120, h: 2880 }));
    }

    #[test]
    fn create_then_move_tracks_actual_size() {
        let mut m = WindowModel::new();
        m.apply(created(1, rect(0, 0, 800, 600), "Xcode"));
        assert_eq!(m.get(1).unwrap().source, rect(0, 0, 800, 600));

        // Host reports an actual size one pixel short of any request (I-4).
        let ev = m.apply(ServerMessage::WindowMoved {
            id: 1,
            rect: rect(0, 0, 800, 599),
        });
        assert_eq!(
            ev,
            vec![ModelEvent::WindowRectChanged {
                id: 1,
                source: rect(0, 0, 800, 599),
                size_changed: true,
            }]
        );
        assert_eq!(m.get(1).unwrap().source, rect(0, 0, 800, 599));
    }

    #[test]
    fn move_without_size_change_flags_no_resize() {
        let mut m = WindowModel::new();
        m.apply(created(1, rect(0, 0, 800, 600), "x"));
        let ev = m.apply(ServerMessage::WindowMoved {
            id: 1,
            rect: rect(100, 50, 800, 600),
        });
        assert_eq!(
            ev,
            vec![ModelEvent::WindowRectChanged {
                id: 1,
                source: rect(100, 50, 800, 600),
                size_changed: false,
            }]
        );
    }

    #[test]
    fn duplicate_create_is_idempotent() {
        let mut m = WindowModel::new();
        assert!(matches!(
            m.apply(created(1, rect(0, 0, 10, 10), "a")).as_slice(),
            [ModelEvent::WindowAdded(_)]
        ));
        // Same id again (e.g. from a resync) updates, doesn't duplicate.
        let ev = m.apply(created(1, rect(0, 0, 20, 20), "a"));
        assert!(matches!(
            ev.as_slice(),
            [ModelEvent::WindowRectChanged { .. }]
        ));
        assert_eq!(m.windows().len(), 1);
    }

    #[test]
    fn destroy_clears_focus() {
        let mut m = WindowModel::new();
        m.apply(created(1, rect(0, 0, 10, 10), "a"));
        m.apply(ServerMessage::WindowFocused { id: 1 });
        assert_eq!(m.focused(), Some(1));
        let ev = m.apply(ServerMessage::WindowDestroyed { id: 1 });
        assert_eq!(ev, vec![ModelEvent::WindowRemoved { id: 1 }]);
        assert_eq!(m.focused(), None);
        assert!(m.windows().is_empty());
    }

    #[test]
    fn move_for_unknown_window_is_ignored() {
        let mut m = WindowModel::new();
        let ev = m.apply(ServerMessage::WindowMoved {
            id: 99,
            rect: rect(0, 0, 1, 1),
        });
        assert!(ev.is_empty());
    }

    #[test]
    fn tile_layout_prunes_stale_windows() {
        let mut m = WindowModel::new();
        m.apply(created(1, rect(0, 0, 10, 10), "a"));
        m.apply(created(2, rect(20, 0, 10, 10), "b"));
        m.apply(created(3, rect(40, 0, 10, 10), "c"));

        // A resync layout that no longer contains window 2.
        let ev = m.apply(ServerMessage::TileLayout {
            windows: vec![
                TileWindow {
                    id: 1,
                    rect: rect(0, 0, 10, 10),
                },
                TileWindow {
                    id: 3,
                    rect: rect(40, 0, 15, 10),
                }, // resized
            ],
            display: Size { w: 100, h: 100 },
        });

        // Window 3 resized, window 2 pruned.
        assert!(ev.contains(&ModelEvent::WindowRectChanged {
            id: 3,
            source: rect(40, 0, 15, 10),
            size_changed: true,
        }));
        assert!(ev.contains(&ModelEvent::Resynced { removed: vec![2] }));
        assert!(m.get(2).is_none());
        assert_eq!(m.windows().len(), 2);
    }

    #[test]
    fn tile_layout_adds_unseen_windows() {
        let mut m = WindowModel::new();
        let ev = m.apply(ServerMessage::TileLayout {
            windows: vec![TileWindow {
                id: 5,
                rect: rect(0, 0, 30, 30),
            }],
            display: Size { w: 100, h: 100 },
        });
        assert!(ev
            .iter()
            .any(|e| matches!(e, ModelEvent::WindowAdded(w) if w.id == 5)));
        assert_eq!(m.get(5).unwrap().source, rect(0, 0, 30, 30));
    }
}
