import ArgumentParser

/// Root command for the Transom host.
///
/// The host runs on the Mac Studio. Its job is to draw: it tiles app windows
/// non-overlapping on a large virtual display (created externally with
/// BetterDisplay), captures that display with ScreenCaptureKit, and reports
/// per-window geometry on a side channel. The Windows client is the real window
/// manager; the host never composites for a human viewer.
///
/// See `docs/architecture.md` for the full design. This binary is a scaffold:
/// only `doctor` is implemented today.
@main
struct Transom: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transom-host",
        abstract: "Host-side agent for the Transom seamless remote windowing system.",
        discussion: """
            Transom streams individual macOS app windows to a Windows client as \
            independent native windows. This host process draws and captures on the \
            Mac; the Windows client manages the windows. This is a pre-alpha \
            prototype: only `doctor` does real work today.
            """,
        version: "0.0.1-alpha",
        subcommands: [
            Doctor.self,
            Displays.self,
            Windows.self,
            Place.self,
            Tile.self,
            Capture.self,
            Probe.self,
            MenuWatch.self,
            EncodeProbe.self,
            Encode.self,
            Serve.self,
            MockResize.self,
            Inject.self,
            MockClient.self,
        ],
        defaultSubcommand: Doctor.self
    )
}
