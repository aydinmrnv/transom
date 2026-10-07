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

        var pids = LivePIDs()
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
            guard let pid = pids.pid(of: app) else {
                return .failure(
                    ProbeError(
                        "\"\(token)\" is running but macOS reports no process id for it, "
                            + "and none could be recovered from its executable path."))
            }
            return .success(
                TargetApp(
                    pid: pid,
                    name: app.localizedName ?? token,
                    bundleID: app.bundleIdentifier))
        default:
            let detail = hits.map {
                "\($0.localizedName ?? "?") (pid \(pids.pid(of: $0) ?? -1))"
            }.joined(separator: ", ")
            return .failure(
                ProbeError(
                    "\"\(token)\" is ambiguous, matched: \(detail). "
                        + "Pass the bundle identifier to disambiguate."))
        }
    }

    /// Every regular/accessory app currently running, for pickers.
    public static func runningApps() -> [TargetApp] {
        var pids = LivePIDs()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName, let pid = pids.pid(of: app) else { return nil }
                return TargetApp(
                    pid: pid,
                    name: name,
                    bundleID: app.bundleIdentifier)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

/// Recovers the pid AX and ScreenCaptureKit need for an `NSRunningApplication`.
///
/// `processIdentifier` cannot be trusted on its own: macOS lists some regular,
/// running apps with pid `-1` (seen on macOS 27 for Xcode, Device Hub and Parsec)
/// while `ps`, AX and SCK all agree on the real one. Passing `-1` on makes the app
/// look like it has no windows, so recover the pid from the process table instead:
/// match the executable path, then let LaunchServices confirm the candidate is
/// this exact instance.
struct LivePIDs {
    /// Built on first miss only; the common case never scans the process table.
    private var pidsByExecutable: [String: [pid_t]]?

    mutating func pid(of app: NSRunningApplication) -> pid_t? {
        if app.processIdentifier > 0 { return app.processIdentifier }
        guard let executable = app.executableURL?.path else { return nil }
        let table = pidsByExecutable ?? Self.scan()
        pidsByExecutable = table
        // The kernel reports resolved paths; LaunchServices may not.
        let resolved = realpath(executable, nil).map { raw -> String in
            defer { free(raw) }
            return String(cString: raw)
        }
        let candidates = table[executable] ?? resolved.flatMap { table[$0] } ?? []
        return candidates.first {
            NSRunningApplication(processIdentifier: $0)?.isEqual(app) ?? false
        }
    }

    private static func scan() -> [String: [pid_t]] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        // Headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return [:] }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var table: [String: [pid_t]] = [:]
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            table[String(cString: path), default: []].append(pid)
        }
        return table
    }
}
