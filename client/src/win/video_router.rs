//! Each window owns a decoder and reference chain; a resize replaces only that
//! generation. The network thread never waits for the UI to ingest a config.
use super::decode::{VideoDecoder, VideoUpdate};
use crate::session::VideoEvent;
use crate::wire::Size;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use windows::Win32::Graphics::Direct3D11::ID3D11Device;

#[derive(Clone, Default)]
pub struct VideoRouter {
    state: Arc<Mutex<State>>,
}
#[derive(Default)]
struct State {
    streams: HashMap<u64, Stream>,
    retired: HashMap<u64, u64>,
}
#[derive(Clone)]
struct Stream {
    generation: u64,
    size: Size,
    decoder: VideoDecoder,
}

impl VideoRouter {
    pub fn receive(&self, display: Size, event: VideoEvent, device: &ID3D11Device) {
        let (id, generation, size, event) = match event {
            VideoEvent::Window {
                id,
                generation,
                size,
                message,
            } => (id, generation, size, *message),
            event => (0, 0, display, event),
        };
        let config = matches!(event, VideoEvent::Config { .. });
        let (decoder, previous) = {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if state.retired.get(&id).is_some_and(|&old| generation <= old) {
                return;
            }
            let current = state.streams.get(&id);
            if current.is_some_and(|s| generation < s.generation) {
                return;
            }
            let replace = current.map_or(true, |s| generation != s.generation);
            let previous = if replace {
                if !config || (current.is_none() && state.streams.len() >= 16) {
                    return;
                }
                state.streams.insert(
                    id,
                    Stream {
                        generation,
                        size,
                        decoder: VideoDecoder::default(),
                    },
                )
            } else {
                None
            };
            let stream = &state.streams[&id];
            if size != stream.size {
                return;
            }
            (stream.decoder.clone(), previous)
        };
        drop(previous);
        decoder.receive(size, event, device);
    }

    pub fn poll(&self) -> Vec<(u64, Size, VideoUpdate)> {
        let streams = self
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .streams
            .clone();
        streams
            .into_iter()
            .map(|(id, s)| (id, s.size, s.decoder.poll()))
            .collect()
    }
    pub fn remove(&self, id: u64) {
        let previous = {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            let previous = state.streams.remove(&id);
            if let Some(stream) = &previous {
                state.retired.insert(id, stream.generation);
            }
            previous
        };
        drop(previous);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn closing_one_window_preserves_other_decoder_and_retires_its_generation() {
        let router = VideoRouter::default();
        let size = Size { w: 2000, h: 1600 };
        {
            let mut state = router.state.lock().unwrap();
            state.streams.insert(
                1,
                Stream {
                    generation: 3,
                    size,
                    decoder: VideoDecoder::default(),
                },
            );
            state.streams.insert(
                2,
                Stream {
                    generation: 4,
                    size,
                    decoder: VideoDecoder::default(),
                },
            );
        }
        router.remove(1);
        let state = router.state.lock().unwrap();
        assert!(!state.streams.contains_key(&1));
        assert_eq!(state.retired[&1], 3);
        assert_eq!(state.streams[&2].generation, 4);
        assert_eq!(state.streams[&2].size, size);
    }
}
