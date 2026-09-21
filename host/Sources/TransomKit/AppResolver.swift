import AppKit

/// A running application the probe can target.
public struct TargetApp: Sendable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
}

public enum AppResolver {
    /// Resolve a user-supplied `<app>` token to a single running application.
    ///
    /// The token matches (case-insensitively) against, in priority order:
    /// bundle identifier, localized name, then executable/bundle base name. This
    /// accepts both `Xcode` (the roadmap's example) and `com.apple.dt.Xcode`.
    ///
    /// Returns `.failure` with a human-readable reason when zero or many apps
    /// match, so callers can surface it verbatim.
    public static func resolve(_ token: String) -> Result<TargetApp, ProbeError> {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular || $0.activationPolicy == .accessory
        }

        func matches(_ app: NSRunningApplication) -> Bool {
            let lower = token.lowercased()
            if let bid = app.bundleIdentifier, bid.lowercased() == lower { return true }
            if let name = app.localizedName, name.lowercased() == lower { return true }
            if let base = app.bundleURL?.deletingPathExtension().lastPathComponent,
                base.lowercased() == lower
            {
                return true
            }
            return false
        }

        let hits = running.filter(matches)

        switch hits.count {
        case 0:
            let names =
                running
                .compactMap { $0.localizedName }
                .sorted()
                .prefix(40)
                .joined(separator: ", ")
            return .failure(
                ProbeError(
                    "no running application matches \"\(token)\". "
                        + "Running apps: \(names)"))
        case 1:
            let app = hits[0]
            return .success(
                TargetApp(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? token,
                    bundleID: app.bundleIdentifier))
        default:
            let detail = hits.map {
                "\($0.localizedName ?? "?") (pid \($0.processIdentifier))"
            }.joined(separator: ", ")
            return .failure(
                ProbeError(
                    "\"\(token)\" is ambiguous, matched: \(detail). "
                        + "Pass the bundle identifier to disambiguate."))
        }
    }

    /// Every regular/accessory app currently running, for pickers.
    public static func runningApps(includeAccessories: Bool = false) -> [TargetApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || (includeAccessories && $0.activationPolicy == .accessory) }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return TargetApp(
                    pid: app.processIdentifier,
                    name: name,
                    bundleID: app.bundleIdentifier)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
