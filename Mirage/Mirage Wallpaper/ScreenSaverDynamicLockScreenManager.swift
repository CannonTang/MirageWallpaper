//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AppKit
import CryptoKit
import Foundation

enum ScreenSaverDynamicLockScreenError: LocalizedError {
    case unavailable
    case notEnabled
    case noWallpaper
    case unsupportedWallpaper
    case storeUnavailable
    case invalidStore
    case conflict
    case restoreConflict

    var errorDescription: String? {
        switch self {
        case .unavailable: return L("屏保动态锁屏需要 macOS 14.2 或更高版本")
        case .notEnabled: return L("请先开启屏保动态锁屏并完成确认")
        case .noWallpaper: return L("请先播放一张壁纸")
        case .unsupportedWallpaper: return L("当前壁纸不能用作动态锁屏")
        case .storeUnavailable: return L("无法访问系统墙纸配置")
        case .invalidStore: return L("系统墙纸配置格式不受支持")
        case .conflict: return L("系统墙纸配置已被其他程序修改，请稍后重试")
        case .restoreConflict: return L("系统墙纸配置已被用户修改，Mirage 未覆盖当前设置")
        }
    }
}

@MainActor
final class ScreenSaverDynamicLockScreenManager: ObservableObject {
    static let shared = ScreenSaverDynamicLockScreenManager()

    @Published private(set) var isEnabled: Bool
    @Published var isConfirmationPresented = false

    private var pendingEnableAction: (() -> Void)?

    private let enabledKey = "Mirage.ScreenSaverDynamicLockScreen.Enabled"
    private let confirmationKey = "Mirage.ScreenSaverDynamicLockScreen.Confirmed"
    private let backupURL: URL
    private let stateURL: URL
    private let storeURL: URL
    private let saverProvider = "com.apple.wallpaper.choice.screen-saver"
    private let lockedKey = "Mirage.ScreenSaverDynamicLockScreen.Locked"

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage", isDirectory: true)
        backupURL = support.appendingPathComponent("dynamic-lock-screen-screen-saver-backup.plist")
        stateURL = support.appendingPathComponent("dynamic-lock-screen-screen-saver-state.plist")
        storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        if DynamicLockScreenModeStore.active == nil,
           UserDefaults.standard.bool(forKey: enabledKey) {
            DynamicLockScreenModeStore.activate(.screenSaver)
        }
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
            && DynamicLockScreenModeStore.active == .screenSaver
        if isEnabled {
            ScreenSaverManager.shared.migrateDynamicLockScreenConfigurationIfNeeded()
        }
        recoverIfNeeded()
    }

    var isAvailable: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    var hasConfirmedWarning: Bool {
        UserDefaults.standard.bool(forKey: confirmationKey)
    }

    var canUse: Bool {
        isAvailable && isEnabled && hasConfirmedWarning && isConfigured
    }

    var isLocked: Bool {
        UserDefaults.standard.bool(forKey: lockedKey)
    }

    var isConfigured: Bool {
        ScreenSaverManager.shared.configuredDynamicLockScreenWallpaperID() != nil
            && ScreenSaverManager.shared.isDynamicLockScreenInstalled
    }

    var configuredWallpaperTitle: String? {
        ScreenSaverManager.shared.configuredDynamicLockScreenWallpaperTitle()
    }

    func requestEnable(afterEnable action: (() -> Void)? = nil) {
        guard isAvailable else { return }
        pendingEnableAction = action
        isConfirmationPresented = true
    }

    func cancelEnableRequest() {
        pendingEnableAction = nil
        isConfirmationPresented = false
    }

    func confirmAndEnable(input: String) -> Bool {
        guard input == "我同意" || input.caseInsensitiveCompare("Agree") == .orderedSame else {
            return false
        }
        UserDefaults.standard.set(true, forKey: confirmationKey)
        isConfirmationPresented = false
        setEnabled(true)
        let action = pendingEnableAction
        pendingEnableAction = nil
        action?()
        return true
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: enabledKey)
            DynamicLockScreenModeStore.deactivate(.screenSaver)
            do {
                try deactivate()
                UserDefaults.standard.set(false, forKey: lockedKey)
                UserDefaults.standard.synchronize()
            } catch { NSLog("[Mirage] 屏保动态锁屏关闭失败: %@", error.localizedDescription) }
            return
        }
        guard isAvailable else { return }
        guard hasConfirmedWarning else {
            requestEnable()
            return
        }
        DynamicLockScreenManager.shared.disableForModeSwitch()
        isEnabled = true
        UserDefaults.standard.set(true, forKey: enabledKey)
        DynamicLockScreenModeStore.activate(.screenSaver)
        ScreenSaverManager.shared.migrateDynamicLockScreenConfigurationIfNeeded()
        if ScreenSaverManager.shared.configuredDynamicLockScreenWallpaperID() != nil,
           !ScreenSaverManager.shared.isDynamicLockScreenInstalled {
            do {
                try ScreenSaverManager.shared.installDynamicLockScreen()
            } catch {
                NSLog("[Mirage] 安装方案 B 锁屏组件失败: %@", error.localizedDescription)
            }
        }
        reassertIfEnabled()
    }

    func disableForModeSwitch() {
        guard isEnabled || DynamicLockScreenModeStore.active == .screenSaver else { return }
        isEnabled = false
        UserDefaults.standard.set(false, forKey: enabledKey)
        DynamicLockScreenModeStore.deactivate(.screenSaver)
        do {
            try deactivate()
            UserDefaults.standard.set(false, forKey: lockedKey)
            UserDefaults.standard.synchronize()
        } catch { NSLog("[Mirage] 屏保动态锁屏切换失败: %@", error.localizedDescription) }
    }

    func configureCurrentWallpaper(_ wallpaper: WEWallpaper,
                                   runtime: WallpaperRuntimeState,
                                   properties: [String: WEProjectProperty],
                                   fps: Int) throws {
        guard canUse || isEnabled else { throw ScreenSaverDynamicLockScreenError.notEnabled }
        guard wallpaper.isValid else { throw ScreenSaverDynamicLockScreenError.noWallpaper }
        guard wallpaper.kind == .video || wallpaper.kind == .scene else {
            throw ScreenSaverDynamicLockScreenError.unsupportedWallpaper
        }
        try ScreenSaverManager.shared.installDynamicLockScreen()
        try ScreenSaverManager.shared.configure(
            with: wallpaper, runtime: runtime, properties: properties, fps: fps,
            forDynamicLockScreen: true)
        reassertIfEnabled()
    }

    func updateLoadFromMemory(_ enabled: Bool) {
        ScreenSaverManager.shared.updateLoadFromMemory(enabled, forDynamicLockScreen: true)
    }

    func reassertIfEnabled() {
        guard isEnabled, DynamicLockScreenModeStore.active == .screenSaver else { return }
        guard ScreenSaverManager.shared.configuredDynamicLockScreenWallpaperID() != nil else { return }
        guard isScreenLocked() else { return }
        do {
            if !ScreenSaverManager.shared.isDynamicLockScreenInstalled {
                try ScreenSaverManager.shared.installDynamicLockScreen()
            }
            try activateStore()
            try ScreenSaverManager.shared.restartForWallpaperStoreChange()
        } catch { NSLog("[Mirage] 屏保动态锁屏槽位恢复失败: %@", error.localizedDescription) }
    }

    @discardableResult
    func enterLockedState() -> Bool {
        guard isEnabled, DynamicLockScreenModeStore.active == .screenSaver,
              ScreenSaverManager.shared.configuredDynamicLockScreenWallpaperID() != nil else { return false }
        do {
            if !ScreenSaverManager.shared.isDynamicLockScreenInstalled {
                try ScreenSaverManager.shared.installDynamicLockScreen()
            }
            try activateStore()
            try ScreenSaverManager.shared.restartForWallpaperStoreChange()
            UserDefaults.standard.set(true, forKey: lockedKey)
            UserDefaults.standard.synchronize()
            return true
        } catch {
            UserDefaults.standard.set(false, forKey: lockedKey)
            UserDefaults.standard.synchronize()
            NSLog("[Mirage] 屏保动态锁屏进入失败: %@", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func leaveLockedState() -> Bool {
        do {
            try deactivate()
            UserDefaults.standard.set(false, forKey: lockedKey)
            UserDefaults.standard.synchronize()
            return true
        } catch {
            NSLog("[Mirage] 屏保动态锁屏恢复失败: %@", error.localizedDescription)
            return false
        }
    }

    func applicationWillTerminate() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        _ = leaveLockedState()
    }

    private func deactivate() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupURL.path) else {
            try? fm.removeItem(at: stateURL)
            return
        }
        let backup = try Data(contentsOf: backupURL)
        let current = try readStore()
        let backupObject = try decodeStore(backup)
        let restored = restoreMirageDesktopChoices(in: current, from: backupObject)
        guard restored.replacements > 0 else {
            try? fm.removeItem(at: backupURL)
            try? fm.removeItem(at: stateURL)
            // Another wallpaper write already replaced Mirage's temporary
            // desktop choice. Preserve that current user-visible state and
            // clear our stale transaction instead of leaving lock mode stuck.
            return
        }
        try writeStore(try encodeStore(restored.value))
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: stateURL)
        try ScreenSaverManager.shared.restartForWallpaperStoreChange()
    }

    private func activateStore() throws {
        let fm = FileManager.default
        let currentData = try Data(contentsOf: storeURL)
        let current = try decodeStore(currentData)
        if storeContainsMirageDesktopChoice(current) { return }
        if fm.fileExists(atPath: stateURL.path) || fm.fileExists(atPath: backupURL.path) {
            // A prior activation can be displaced by a late system wallpaper
            // write. Since Mirage's choice is no longer present, the current
            // store is the new safe restore point; discard only our stale
            // transaction files and activate again from that state.
            try? fm.removeItem(at: stateURL)
            try? fm.removeItem(at: backupURL)
        }
        let transformed = try transformStore(current)
        guard transformed.replacements > 0 else { throw ScreenSaverDynamicLockScreenError.invalidStore }
        try fm.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try currentData.write(to: backupURL, options: .atomic)
        let transformedData = try encodeStore(transformed.value)
        let state: [String: Any] = [
            "version": 1,
            "backupSHA256": digest(currentData),
            "activeSHA256": digest(transformedData),
            "saverPath": ScreenSaverManager.shared.dynamicLockScreenInstalledURL
                .resolvingSymlinksInPath().path
        ]
        let stateData = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        try stateData.write(to: stateURL, options: .atomic)
        try writeStore(transformedData)
    }

    private func transformStore(_ value: Any) throws -> (value: Any, replacements: Int) {
        var replacements = 0
        func visit(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var result = dictionary
                if let idle = dictionary["Idle"] as? [String: Any],
                   var desktop = dictionary["Desktop"] as? [String: Any],
                   let idleContent = idle["Content"] as? [String: Any] {
                    desktop["Content"] = screenSaverContent(from: idleContent)
                    result["Desktop"] = desktop
                    replacements += 1
                }
                for (key, nested) in result {
                    if key == "Desktop" { continue }
                    result[key] = visit(nested)
                }
                if let desktop = result["Desktop"] {
                    result["Desktop"] = visit(desktop)
                }
                return result
            }
            if let array = value as? [Any] { return array.map(visit) }
            return value
        }
        let transformed = visit(value)
        return (transformed, replacements)
    }

    private func screenSaverContent(from idleContent: [String: Any]) -> [String: Any] {
        var content = idleContent
        let configuration: [String: Any] = [
            "module": ["relative": ScreenSaverManager.shared.dynamicLockScreenInstalledURL.absoluteString]
        ]
        let data = (try? PropertyListSerialization.data(
            fromPropertyList: configuration, format: .binary, options: 0)) ?? Data()
        content["Choices"] = [[
            "Configuration": data,
            "Files": [],
            "Provider": saverProvider
        ]]
        return content
    }

    private func decodeStore(_ data: Data) throws -> Any {
        try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    private func encodeStore(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func readStore() throws -> Any {
        try decodeStore(Data(contentsOf: storeURL))
    }

    private func writeStore(_ data: Data) throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".Index-\(UUID().uuidString).plist")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: storeURL.path) {
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: storeURL)
        }
    }

    private func storeContainsMirageDesktopChoice() -> Bool {
        guard let value = try? readStore() else { return false }
        return storeContainsMirageDesktopChoice(value)
    }

    private func storeContainsMirageDesktopChoice(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let desktop = dictionary["Desktop"] as? [String: Any],
               let content = desktop["Content"] as? [String: Any],
               let choices = content["Choices"] as? [[String: Any]],
               choices.contains(where: { choice in
                   guard choice["Provider"] as? String == saverProvider,
                         let configuration = choice["Configuration"] as? Data,
                         let object = try? PropertyListSerialization.propertyList(
                            from: configuration, options: [], format: nil) as? [String: Any],
                         let module = object["module"] as? [String: Any],
                         let path = module["relative"] as? String else { return false }
                   return isMirageSaverPath(path)
               }) {
                return true
            }
            return dictionary.values.contains { storeContainsMirageDesktopChoice($0) }
        }
        if let array = value as? [Any] { return array.contains { storeContainsMirageDesktopChoice($0) } }
        return false
    }

    private func restoreMirageDesktopChoices(in current: Any, from backup: Any) -> (value: Any, replacements: Int) {
        var replacements = 0
        func visit(_ current: Any, _ backup: Any?) -> Any {
            if let currentDictionary = current as? [String: Any] {
                let backupDictionary = backup as? [String: Any]
                var result = currentDictionary
                if let desktop = currentDictionary["Desktop"] as? [String: Any],
                   isMirageDesktop(desktop),
                   let original = backupDictionary?["Desktop"] {
                    result["Desktop"] = original
                    replacements += 1
                }
                for (key, value) in result where key != "Desktop" {
                    result[key] = visit(value, backupDictionary?[key])
                }
                return result
            }
            if let currentArray = current as? [Any] {
                let backupArray = backup as? [Any]
                return currentArray.enumerated().map { index, value in
                    visit(value, backupArray.flatMap { index < $0.count ? $0[index] : nil })
                }
            }
            return current
        }
        return (visit(current, backup), replacements)
    }

    private func isMirageDesktop(_ desktop: [String: Any]) -> Bool {
        guard let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              choices.count == 1,
              let choice = choices.first,
              choice["Provider"] as? String == saverProvider,
              let configuration = choice["Configuration"] as? Data,
              let object = try? PropertyListSerialization.propertyList(
                  from: configuration, options: [], format: nil) as? [String: Any],
              let module = object["module"] as? [String: Any],
              let path = module["relative"] as? String else { return false }
        return isMirageSaverPath(path)
    }

    private func isMirageSaverPath(_ path: String) -> Bool {
        guard let path = URL(string: path)?.standardizedFileURL.path else { return false }
        return path == ScreenSaverManager.shared.dynamicLockScreenInstalledURL.standardizedFileURL.path
            || path == ScreenSaverManager.shared.installedURL.standardizedFileURL.path
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func recoverIfNeeded() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            try? FileManager.default.removeItem(at: backupURL)
            return
        }
        guard isEnabled, DynamicLockScreenModeStore.active == .screenSaver else {
            if storeContainsMirageDesktopChoice() {
                do { try deactivate() } catch { NSLog("[Mirage] 屏保动态锁屏恢复失败: %@", error.localizedDescription) }
            } else {
                try? FileManager.default.removeItem(at: stateURL)
                try? FileManager.default.removeItem(at: backupURL)
            }
            return
        }
        if !isScreenLocked(), let current = try? readStore() {
            if storeContainsMirageDesktopChoice(current) {
                do { try deactivate() } catch { NSLog("[Mirage] 屏保动态锁屏恢复失败: %@", error.localizedDescription) }
            } else {
                try? FileManager.default.removeItem(at: stateURL)
                try? FileManager.default.removeItem(at: backupURL)
            }
        }
    }

    private func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        for key in ["CGSSessionScreenIsLocked", "kCGSSessionScreenIsLocked"] {
            if let value = session[key] as? NSNumber { return value.boolValue }
            if let value = session[key] as? Bool { return value }
        }
        return false
    }
}
