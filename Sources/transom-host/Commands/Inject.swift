import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation
import TransomKit

/// `inject <app> <index> <display>` — post input into a real window **locally**,
/// with no wire in the loop (issue #7 verification).
///
/// This is the fast way to answer the empirical question the issue calls the
/// whole risk: *which coordinate space does `CGEventPost` actually use on this
/// machine?* It reads the window's real AX frame, converts it to a VDS rect
/// exactly as the watcher does, then drives the production `InputInjector` — so
/// the CS → VDS → AX → `CGEventPost` chain under test is the same one `serve`
/// uses. `mock-client` exercises the same path *over the wire*.
///
/// Actions run in this order when combined: `--focus`, click (`--x`/`--y`),
/// `--type`, `--chord`.
struct Inject: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inject",
        abstract:
            "Post a click / text / chord into a window locally; log the full coordinate chain.")

    @Argument(help: "Target app: a name like \"TextEdit\" or a bundle id.")
    var app: String

    @Argument(help: "Window index, as printed by `windows`.")
    var index: Int

    @Argument(help: "Display id, as printed by `displays`.")
    var display: UInt32

    @Option(name: .long, help: "Click at window-local x (physical pixels).")
    var x: Int?

    @Option(name: .long, help: "Click at window-local y (physical pixels).")
    var y: Int?

    @Option(name: .long, help: "Mouse button for the click: left | right | middle.")
    var button: String = "left"

    @Option(name: .long, help: "Type this text into the window.")
    var type: String?

    @Option(name: .long, help: "Send a chord in Windows-side names, e.g. \"ctrl+a\" (→ ⌘A).")
    var chord: String?

    @Flag(
        name: .long, help: "Raise/focus the window first (also happens implicitly before a click).")
    var focus: Bool = false

    @Flag(
        name: .long,
        help: "Map modifiers namesake (Ctrl→Control) instead of the default swap (Ctrl→Command).")
    var namesakeModifiers: Bool = false

    /// Inter-event delay so the target app registers each event (mouse down/up
    /// pacing, key repeat). CGEventPost is synchronous but delivery is not.
    @Option(name: .long, help: "Milliseconds to wait between posted events.")
    var stepMs: Int = 12

    func run() throws {
        setvbuf(stdout, nil, _IONBF, 0)

        guard AXIsProcessTrusted() else {
            throw ProbeError(
                "Accessibility is not granted (required for CGEventPost). Run `doctor`.")
        }

        let target: TargetApp
        switch AppResolver.resolve(app) {
        case .success(let t): target = t
        case .failure(let e): throw e
        }
        guard let disp = TransomKit.Displays.byID(display) else {
            throw ProbeError("no active display with id \(display). See `displays`.")
        }

        let windows = AXWindow.windows(pid: target.pid)
        guard index >= 0, index < windows.count else {
            throw ProbeError(
                "window index \(index) out of range (app has \(windows.count) window(s)).")
        }
        let window = windows[index]
        guard let frame = window.frame() else {
            throw ProbeError(
                "AX would not report the window's frame; cannot translate coordinates.")
        }

        // Convert the real AX frame → VDS pixels exactly as the watcher does, and
        // seed a one-window registry so the injector's lookup path is identical to
        // production.
        let vds = Coordinates.displayPixels(
            fromAXRect: frame, displayOriginPoints: disp.originPoints, scale: disp.scale)
        let rect = WireRect(clampingVDSPixels: vds)

        let registry = WindowRegistry()
        let (id, _) = registry.id(for: window.element)
        registry.record(id: id, rect: rect, title: window.title)

        let injector = InputInjector(
            display: disp, registry: registry,
            modifierMap: namesakeModifiers ? .namesake : .swap)
        injector.onTrace = { line in print("  \(line)") }

        print("inject: \(target.name) window[\(index)] \"\(window.title)\" on display \(display)")
        print(
            "  AX frame (pt): origin=(\(i(frame.origin.x)),\(i(frame.origin.y))) "
                + "size=\(i(frame.size.width))x\(i(frame.size.height))  scale=\(disp.scale)x")
        print("  window VDS rect (px): x=\(rect.x) y=\(rect.y) w=\(rect.w) h=\(rect.h)")
        print(
            "  modifiers: \(namesakeModifiers ? "namesake (Ctrl→Control)" : "swap (Ctrl→Command)")")
        print(String(repeating: "-", count: 60))

        var didSomething = false
        let ts: UInt64 = 0

        if focus {
            injector.requestFocus(id: id)
            didSomething = true
            step()
        }

        if let x, let y {
            guard let mb = MouseButton(rawValue: button) else {
                throw ProbeError("unknown button \"\(button)\" (use left/right/middle).")
            }
            let ux = UInt32(clamping: x)
            let uy = UInt32(clamping: y)
            injector.inject(id: id, event: .mouseMove(x: ux, y: uy), ts: ts)
            step()
            injector.inject(id: id, event: .mouseDown(x: ux, y: uy, button: mb), ts: ts)
            step()
            injector.inject(id: id, event: .mouseUp(x: ux, y: uy, button: mb), ts: ts)
            step()
            didSomething = true

            // Empirical coordinate-space check (issue #7): after posting, the real
            // cursor sits where the event was placed. Read it back and compare to
            // the AX point we computed. A 2x mismatch here would mean CGEventPost
            // is pixel-space, not point-space, and the `/ scale` step is wrong.
            let expected = Coordinates.axGlobalPoint(
                fromWindowLocalPixels: CGPoint(x: Double(ux), y: Double(uy)),
                windowOriginVDS: CGPoint(x: Double(rect.x), y: Double(rect.y)),
                displayOriginPoints: disp.originPoints, scale: disp.scale)
            if let actual = CGEvent(source: nil)?.location {
                let dx = actual.x - expected.x
                let dy = actual.y - expected.y
                let ok = abs(dx) <= 1 && abs(dy) <= 1
                print(
                    "  cursor readback: expected ax=(\(fmt(expected.x)),\(fmt(expected.y)))pt  "
                        + "actual=(\(fmt(actual.x)),\(fmt(actual.y)))pt  "
                        + "Δ=(\(fmt(dx)),\(fmt(dy)))  [\(ok ? "POINT-SPACE ✓" : "MISMATCH")]")
            }
        }

        if let type {
            let (events, unsupported) = MockInput.typing(type)
            if !unsupported.isEmpty {
                print(
                    "  note: unsupported characters dropped: \(unsupported.map(String.init).joined())"
                )
            }
            for event in events {
                injector.inject(id: id, event: event, ts: ts)
                step()
            }
            didSomething = true
        }

        if let chord {
            let (events, error) = MockInput.chord(chord)
            if let error { throw ProbeError("bad --chord: \(error)") }
            for event in events {
                injector.inject(id: id, event: event, ts: ts)
                step()
            }
            didSomething = true
        }

        if !didSomething {
            print("  (no action requested — pass --focus, --x/--y, --type, or --chord)")
        }
        print("inject: done.")
    }

    private func step() {
        if stepMs > 0 { usleep(useconds_t(stepMs * 1000)) }
    }

    private func i(_ v: CGFloat) -> Int { Int(v.rounded()) }
    private func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
}
