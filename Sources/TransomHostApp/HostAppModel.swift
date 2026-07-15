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

    private var session: HostSession?
    private var pollTimer: Timer?

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
        let session = self.session
        self.session = nil
        running = false
        starting = false
        status = HostStatus()
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
}
