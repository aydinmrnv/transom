import AppKit
import Foundation
import SwiftUI
import TransomKit

/// Drives one `HostSession` from the UI: start it, poll a status snapshot onto
/// `@Published` state a few times a second, and stop it. All the real work lives
/// in `HostSession`; this is the SwiftUI-side adapter, deliberately thin.
@MainActor
final class HostAppModel: ObservableObject {
    @Published var running = false
    @Published var starting = false
    @Published var status = HostStatus()
    @Published var startError: String?

    /// Live stream-preview state, refreshed on a faster timer than `status` so the
    /// picture and the window overlays feel live (window moves during a client
    /// drag come in around 10Hz). Driven by `HostSession.preview()`.
    @Published var previewImage: NSImage?
    @Published var previewWindows: [PreviewWindow] = []
    @Published var displayPixelSize: CGSize = .zero

    private var session: HostSession?
    private var pollTimer: Timer?
    private var previewTimer: Timer?

    /// How often the preview panel refreshes. ~12Hz is smooth enough for a control
    /// panel while staying cheap (each tick resamples one downscaled frame).
    private static let previewInterval = 1.0 / 12.0

    func start(config: HostConfig) {
        guard session == nil else { return }
        startError = nil
        starting = true
        let session = HostSession(config: config)
        self.session = session
        Task { @MainActor in
            do {
                try await session.start()
                self.running = true
                self.starting = false
                self.status = session.status()
                self.startPolling()
                self.startPreview()
            } catch {
                self.startError = "\(error)"
                self.starting = false
                self.session = nil
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        previewTimer?.invalidate()
        previewTimer = nil
        let session = self.session
        self.session = nil
        running = false
        starting = false
        status = HostStatus()
        previewImage = nil
        previewWindows = []
        displayPixelSize = .zero
        if let session {
            Task { await session.stop() }
        }
    }

    private func startPolling() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard let session else { return }
        status = session.status()
    }

    private func startPreview() {
        let timer = Timer(timeInterval: Self.previewInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPreview() }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func pollPreview() {
        guard let session else { return }
        let snap = session.preview()
        if let cg = snap.image {
            previewImage = NSImage(
                cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            previewImage = nil
        }
        previewWindows = snap.windows.map(PreviewWindow.init(entry:))
        displayPixelSize = CGSize(
            width: snap.displayPixelWidth, height: snap.displayPixelHeight)
    }
}
