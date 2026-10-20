import Testing

@testable import TransomKit

@Suite("App resolution")
struct AppResolverTests {
    @Test("the picker never offers an app without a usable process id")
    func runningAppsHaveRealPIDs() {
        // macOS lists some running apps with pid -1; AX and SCK need the real one,
        // and the picker keys its selection on it.
        for includingAccessoryApps in [false, true] {
            let pids = AppResolver.runningApps(includingAccessoryApps: includingAccessoryApps).map(\.pid)
            #expect(pids.allSatisfy { $0 > 0 })
            #expect(Set(pids).count == pids.count)
        }
    }
}
