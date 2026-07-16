import AppKit
import SwiftUI
import TransomKit

/// One window as the preview panel needs it: its wire id, title, and rect in
/// **VDS pixels** (the same space the captured frame's pixels live in, I-3), so a
/// single scale factor maps it onto the displayed image.
struct PreviewWindow: Identifiable, Equatable {
    let id: UInt64
    let title: String
    let rect: CGRect

    /// Build from a registry entry, converting the wire rect's `UInt32` fields to
    /// the `CGRect` the overlay math wants.
    init(entry: WindowRegistry.Entry) {
        self.id = entry.id
        self.title = entry.title
        self.rect = CGRect(
            x: Double(entry.rect.x), y: Double(entry.rect.y),
            width: Double(entry.rect.w), height: Double(entry.rect.h))
    }
}

/// The live stream-preview panel: what the host is sending, with every tracked
/// window outlined and the selected one highlighted.
///
/// The captured frame is drawn `scaledToFit` inside a box locked to the display's
/// aspect ratio, so the box *is* the image rect — no letterboxing to correct for.
/// Window rects (VDS pixels) then map on with one scale factor. When video is off
/// or no frame has arrived, the same box becomes a schematic of the display so the
/// layout and selection are still visible.
struct StreamPreview: View {
    let image: NSImage?
    /// Display size in VDS pixels; drives the aspect ratio and the overlay scale.
    let displaySize: CGSize
    let windows: [PreviewWindow]
    let showOutlines: Bool
    let showLabels: Bool
    let videoEnabled: Bool
    @Binding var selectedID: UInt64?

    private var aspect: CGFloat {
        displaySize.width > 0 && displaySize.height > 0
            ? displaySize.width / displaySize.height : 16.0 / 9.0
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.9))

            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }

            // A transparent catcher below the overlays: a tap on empty space
            // clears the selection. Window overlays sit on top and consume their
            // own taps, so this only fires when nothing was hit.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selectedID = nil }

            // Always present, so a window stays clickable and the selected one
            // stays highlighted even with outlines toggled off — that toggle hides
            // only the *unselected* outlines, not selection itself.
            overlays
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 460)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: videoEnabled ? "hourglass" : "rectangle.on.rectangle")
                .font(.system(size: 34)).foregroundStyle(.white.opacity(0.45))
            Text(
                videoEnabled
                    ? "waiting for the first frame…"
                    : "video streaming is off — showing the window layout only"
            )
            .font(.callout).foregroundStyle(.white.opacity(0.6))
            .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var overlays: some View {
        GeometryReader { geo in
            let sx = geo.size.width / max(displaySize.width, 1)
            let sy = geo.size.height / max(displaySize.height, 1)
            ForEach(windows) { win in
                let f = CGRect(
                    x: win.rect.minX * sx, y: win.rect.minY * sy,
                    width: win.rect.width * sx, height: win.rect.height * sy)
                WindowOutline(
                    window: win, frame: f,
                    selected: win.id == selectedID,
                    outlineVisible: showOutlines, showLabel: showLabels
                )
                .onTapGesture {
                    selectedID = (selectedID == win.id) ? nil : win.id
                }
            }
        }
    }
}

/// A single window's outline within the preview. Unselected windows get a thin
/// neutral stroke (only when `outlineVisible`); the selected one always gets a
/// bold accent stroke, a translucent fill, and (optionally) a title chip — that is
/// the "highlight the selected window". The hit region is always live, so a window
/// stays clickable regardless of outline visibility.
private struct WindowOutline: View {
    let window: PreviewWindow
    let frame: CGRect
    let selected: Bool
    let outlineVisible: Bool
    let showLabel: Bool

    var body: some View {
        let color: Color = selected ? .accentColor : .white
        // Draw the outline for the selected window always; for the rest only when
        // outlines are enabled. Either way the shape below stays tappable.
        let drawn = selected || outlineVisible
        ZStack(alignment: .topLeading) {
            if drawn {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(selected ? 0.18 : 0.0))
                RoundedRectangle(cornerRadius: 3)
                    .stroke(
                        color.opacity(selected ? 1.0 : 0.55),
                        lineWidth: selected ? 3 : 1.5)

                if showLabel && (selected || frame.width > 54) {
                    Text(labelText)
                        .font(
                            .system(size: 10, weight: selected ? .bold : .regular, design: .rounded)
                        )
                        .lineLimit(1)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(
                            color.opacity(selected ? 0.9 : 0.55),
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .padding(3)
                        .frame(maxWidth: frame.width, alignment: .leading)
                }
            }
        }
        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
        .position(x: frame.midX, y: frame.midY)
        .contentShape(Rectangle())
    }

    private var labelText: String {
        window.title.isEmpty ? "window \(window.id)" : window.title
    }
}
