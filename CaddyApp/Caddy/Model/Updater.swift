import Sparkle
import SwiftUI

/// Sparkle, checking daily for a newer release on GitHub (`SUFeedURL` in
/// Info.plist) and offering Caddy › Check for Updates…. Updates are signed
/// with the EdDSA key in the login Keychain (account `caddy`); `SUPublicEDKey`
/// is its public half. Debug builds don't start it, so they're never replaced
/// by a release.
@Observable
final class Updater {
    private(set) var canCheck = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        #if DEBUG
        let starts = false
        #else
        let starts = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: starts, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheck = canCheck }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Caddy › Check for Updates…, greyed out while a check is already running.
struct CheckForUpdatesButton: View {
    let updater: Updater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheck)
    }
}
