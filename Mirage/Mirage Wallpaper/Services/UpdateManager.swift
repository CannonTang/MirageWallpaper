//
//  UpdateManager.swift
//  Mirage Wallpaper
//

import Cocoa
import Sparkle

/// Owns Mirage's Sparkle updater and exposes the two user-facing update paths:
/// the regular channel and the opt-in beta channel.
@MainActor
final class UpdateManager: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateManager()

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private var hasStarted = false

    var isUpdateServiceAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MirageDistributionChannel") as? String == "upstream"
    }

    private override init() {
        super.init()
    }

    func start() {
        guard isUpdateServiceAvailable, !hasStarted else { return }
        hasStarted = true
        updaterController.startUpdater()
        applyAutomaticUpdatePreference()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard isUpdateServiceAvailable else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L("自定义版本未启用自动更新")
            alert.informativeText = L("此构建来自 CannonTang/MirageWallpaper，不会连接上游更新源，以免覆盖本地改造。请从你的 fork 获取后续版本。")
            alert.addButton(withTitle: L("好"))
            alert.runModal()
            return
        }
        updaterController.checkForUpdates(sender)
    }

    func applyAutomaticUpdatePreference() {
        guard isUpdateServiceAvailable else { return }
        let enabled = AppDelegate.shared.globalSettingsViewModel.settings.shouldAutomaticallyUpdate
        updaterController.updater.automaticallyChecksForUpdates = enabled
        updaterController.updater.automaticallyDownloadsUpdates = enabled
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        guard AppDelegate.shared.globalSettingsViewModel.settings.shouldReceivePrereleaseUpdates else {
            return []
        }
        return ["beta"]
    }
}
