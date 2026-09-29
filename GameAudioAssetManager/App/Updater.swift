import AppKit
import Observation
import Sparkle

/// Sparkle auto-updates. Only release builds carry a feed URL (set by scripts/release.sh),
/// so development builds never update themselves.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    private(set) var isAvailable = false

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    func start() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard controller == nil, !feed.isEmpty,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        isAvailable = true
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
