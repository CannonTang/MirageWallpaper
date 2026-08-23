//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AppKit
import CryptoKit
import Foundation

struct DynamicLockScreenDisplayConfiguration: Codable {
    let displayID: UInt32
    let wallpaperID: String
    let title: String
    let kind: String
    let renderDirectory: String
    let entryPath: String
    let previewPath: String?
    var desktopFallbackPath: String?
    let rawProperties: [String: AnyCodableValue]
    let fps: Int
    let fillMode: String
    var loadFromMemory: Bool?
}

struct DynamicLockScreenConfiguration: Codable {
    let version: Int
    var enabled: Bool?
    var displays: [String: DynamicLockScreenDisplayConfiguration]
}

enum AnyCodableValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    init(_ value: Any) {
        switch value {
        case let value as String: self = .string(value)
        case let value as NSString: self = .string(value as String)
        case let value as Bool: self = .bool(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as [String: Any]: self = .object(value.mapValues(AnyCodableValue.init))
        case let value as [Any]: self = .array(value.map(AnyCodableValue.init))
        default: self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: AnyCodableValue].self) { self = .object(value); return }
        self = .array(try container.decode([AnyCodableValue].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

@MainActor
final class DynamicLockScreenManager: ObservableObject {
    static let shared = DynamicLockScreenManager()

    @Published private(set) var isEnabled: Bool
    @Published var isConfirmationPresented = false

    private let enabledKey = "Mirage.DynamicLockScreen.Enabled"
    private let confirmationKey = "Mirage.DynamicLockScreen.Confirmed"
    private let appGroupID = "group.cn.laobamac.Mirage"
    private let configurationName = "dynamic-lock-screen.json"

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        discardUnsupportedConfiguration()
    }

    var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var hasConfirmedWarning: Bool {
        UserDefaults.standard.bool(forKey: confirmationKey)
    }

    var canUse: Bool {
        isAvailable && isEnabled && hasConfirmedWarning && sharedContainerURL != nil
    }

    var isConfigured: Bool {
        guard let url = configurationURL,
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(DynamicLockScreenConfiguration.self, from: data) else { return false }
        return configuration.enabled != false && !configuration.displays.isEmpty && configuration.displays.values.allSatisfy {
            $0.kind == WallpaperKind.video.rawValue || $0.kind == WallpaperKind.scene.rawValue
        }
    }

    var configurationURL: URL? {
        sharedContainerURL?.appendingPathComponent(configurationName)
    }

    var configuredWallpaperTitle: String? {
        guard let url = configurationURL,
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(DynamicLockScreenConfiguration.self, from: data) else { return nil }
        return configuration.displays.values.first?.title
    }

    func requestEnable() {
        guard isAvailable else { return }
        isConfirmationPresented = true
    }

    func confirmAndEnable(input: String) -> Bool {
        guard input == "我同意" || input.caseInsensitiveCompare("Agree") == .orderedSame else { return false }
        UserDefaults.standard.set(true, forKey: confirmationKey)
        UserDefaults.standard.set(true, forKey: enabledKey)
        isEnabled = true
        isConfirmationPresented = false
        activateStoredConfiguration()
        registerExtension()
        return true
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: enabledKey)
            clearConfiguration()
            return
        }
        guard hasConfirmedWarning else {
            requestEnable()
            return
        }
        guard isAvailable else { return }
        isEnabled = true
        UserDefaults.standard.set(true, forKey: enabledKey)
        activateStoredConfiguration()
        registerExtension()
    }

    func configureCurrentWallpaper(_ wallpaper: WEWallpaper,
                                   runtime: WallpaperRuntimeState,
                                   properties: [String: WEProjectProperty],
                                   fps: Int,
                                   displayIDs: [UInt32]) throws {
        guard canUse else { throw DynamicLockScreenError.notEnabled }
        guard wallpaper.isValid else { throw DynamicLockScreenError.noWallpaper }
        guard wallpaper.kind == .video || wallpaper.kind == .scene else {
            throw DynamicLockScreenError.unsupportedWallpaper
        }
        guard let container = sharedContainerURL else { throw DynamicLockScreenError.appGroupUnavailable }

        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let deployment = try deploy(wallpaper: wallpaper, in: container)
        var keepDeployment = false
        defer {
            if !keepDeployment { try? FileManager.default.removeItem(at: deployment.root) }
        }
        var rawPropertyValues: [String: Any] = [:]
        for (key, property) in properties where wallpaper.kind == .scene {
            switch property.propertyType {
            case .color:
                rawPropertyValues[key] = ["type": "color", "value": property.value.stringValue]
            case .bool:
                rawPropertyValues[key] = property.value.boolValue
            case .slider:
                rawPropertyValues[key] = property.value.doubleValue
            case .scenetexture, .file:
                let value = try deployPropertyAsset(property.value.stringValue, key: key, in: deployment.root)
                rawPropertyValues[key] = ["type": "scenetexture", "value": value]
            case .combo:
                rawPropertyValues[key] = property.value.jsonObjectValue
            default:
                rawPropertyValues[key] = property.value.stringValue
            }
        }
        let configuration = DynamicLockScreenConfiguration(
            version: 2,
            enabled: true,
            displays: Dictionary(uniqueKeysWithValues: displayIDs.map { displayID in
                let fallbackSource = DesktopOverrideService.shared.dynamicLockScreenFallbackURL(
                    forDisplay: displayID)
                let fallbackURL = fallbackSource.flatMap {
                    try? deployDesktopFallback(source: $0, displayID: displayID, in: container)
                }
                let record = DynamicLockScreenDisplayConfiguration(
                    displayID: displayID,
                    wallpaperID: wallpaper.id,
                    title: wallpaper.project.title,
                    kind: wallpaper.kind.rawValue,
                    renderDirectory: deployment.renderDirectory.path,
                    entryPath: deployment.entryURL.path,
                    previewPath: deployment.previewURL?.path,
                    desktopFallbackPath: fallbackURL?.path,
                    rawProperties: rawPropertyValues.mapValues(AnyCodableValue.init),
                    fps: min(max(fps, 10), 60),
                    fillMode: runtime.fillMode.rawValue,
                    loadFromMemory: (AppDelegate.shared.globalSettingsViewModel.settings.wallpaperLoadSource ?? .disk) == .memory
                )
                return ("display-\(displayID)", record)
            })
        )
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: container.appendingPathComponent(configurationName), options: .atomic)
        keepDeployment = true
        notifyConfigurationChanged()
        cleanupDeployments(except: deployment.root)
        cleanupDesktopFallbacks()
    }

    func updateLoadFromMemory(_ enabled: Bool) {
        guard let configurationURL,
              let data = try? Data(contentsOf: configurationURL),
              var configuration = try? JSONDecoder().decode(
                DynamicLockScreenConfiguration.self, from: data)
        else { return }
        for key in configuration.displays.keys {
            configuration.displays[key]?.loadFromMemory = enabled
        }
        guard let updated = try? JSONEncoder().encode(configuration),
              (try? updated.write(to: configurationURL, options: .atomic)) != nil
        else { return }
        notifyConfigurationChanged()
    }

    func refreshDesktopFallback(forDisplay displayID: UInt32) {
        guard let configurationURL,
              let data = try? Data(contentsOf: configurationURL),
              var configuration = try? JSONDecoder().decode(DynamicLockScreenConfiguration.self, from: data),
              var record = configuration.displays["display-\(displayID)"],
              let container = sharedContainerURL,
              let source = DesktopOverrideService.shared.dynamicLockScreenFallbackURL(forDisplay: displayID),
              let fallback = try? deployDesktopFallback(source: source, displayID: displayID, in: container)
        else { return }
        record.desktopFallbackPath = fallback.path
        configuration.displays["display-\(displayID)"] = record
        guard let updated = try? JSONEncoder().encode(configuration),
              (try? updated.write(to: configurationURL, options: .atomic)) != nil else {
            try? FileManager.default.removeItem(at: fallback)
            return
        }
        notifyDesktopFallbackChanged()
        cleanupDesktopFallbacks()
    }

    func refreshDesktopFallbacks() {
        guard let configurationURL,
              let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(DynamicLockScreenConfiguration.self, from: data)
        else { return }
        configuration.displays.values.forEach { refreshDesktopFallback(forDisplay: $0.displayID) }
    }

    func clearConfiguration() {
        refreshDesktopFallbacks()
        guard let configurationURL,
              let data = try? Data(contentsOf: configurationURL),
              var configuration = try? JSONDecoder().decode(
                DynamicLockScreenConfiguration.self, from: data)
        else {
            notifyConfigurationChanged()
            return
        }
        configuration.enabled = false
        if let updated = try? JSONEncoder().encode(configuration) {
            try? updated.write(to: configurationURL, options: .atomic)
        }
        notifyConfigurationChanged()
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private func playableEntryURL(for wallpaper: WEWallpaper) -> URL {
        let source = wallpaper.resolvedEntryURL.resolvingSymlinksInPath()
        guard wallpaper.kind == .video else { return source }
        let digest = SHA256.hash(data: Data(source.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage/VideoCache", isDirectory: true)
            .appendingPathComponent("\(digest).mp4")
        return FileManager.default.fileExists(atPath: cache.path) ? cache : source
    }

    private func deploy(wallpaper: WEWallpaper, in container: URL) throws -> (root: URL, renderDirectory: URL, entryURL: URL, previewURL: URL?) {
        let deployments = container.appendingPathComponent("DynamicLockScreen/Deployments", isDirectory: true)
        try FileManager.default.createDirectory(at: deployments, withIntermediateDirectories: true)
        let root = deployments.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let source = playableEntryURL(for: wallpaper)
        let renderDirectory = root.appendingPathComponent("render", isDirectory: true)
        do {
            let entryURL: URL
            if wallpaper.kind == .scene {
                let sourceRoot = wallpaper.renderDirectory.resolvingSymlinksInPath()
                try FileManager.default.copyItem(at: sourceRoot, to: renderDirectory)
                let relativeEntry = source.path.hasPrefix(sourceRoot.path + "/")
                    ? String(source.path.dropFirst(sourceRoot.path.count + 1))
                    : source.lastPathComponent
                entryURL = renderDirectory.appendingPathComponent(relativeEntry)
                if !FileManager.default.fileExists(atPath: entryURL.path) {
                    try FileManager.default.createDirectory(at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try linkOrCopy(source, to: entryURL)
                }
            } else {
                try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
                entryURL = renderDirectory.appendingPathComponent(source.lastPathComponent)
                try linkOrCopy(source, to: entryURL)
            }
            let previewURL = try deployPreview(for: wallpaper, in: root)
            return (root, renderDirectory, entryURL, previewURL)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func deployPropertyAsset(_ path: String, key: String, in root: URL) throws -> String {
        guard !path.isEmpty, (path as NSString).isAbsolutePath else { return path }
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: source.path) else { return path }
        let digest = SHA256.hash(data: Data("\(key)|\(source.path)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("property-assets/\(digest)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent, isDirectory: source.hasDirectoryPath)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination.path
    }

    private func deployPreview(for wallpaper: WEWallpaper, in root: URL) throws -> URL? {
        let source = wallpaper.previewURL.resolvingSymlinksInPath()
        guard !source.hasDirectoryPath, FileManager.default.fileExists(atPath: source.path) else { return nil }
        let extensionName = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
        let destination = root.appendingPathComponent("preview.\(extensionName)")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try linkOrCopy(source, to: destination)
        }
        return destination
    }

    private func deployDesktopFallback(source: URL, displayID: UInt32, in container: URL) throws -> URL {
        let source = source.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let directory = container.appendingPathComponent("DynamicLockScreen/DesktopFallbacks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extensionName = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let destination = directory.appendingPathComponent(
            "display-\(displayID)-\(UUID().uuidString.lowercased()).\(extensionName)")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func linkOrCopy(_ source: URL, to destination: URL) throws {
        do {
            try FileManager.default.linkItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func cleanupDeployments(except active: URL) {
        let directory = active.deletingLastPathComponent()
        let configurationURL = configurationURL
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            guard let configurationURL,
                  let data = try? Data(contentsOf: configurationURL),
                  let configuration = try? JSONDecoder().decode(DynamicLockScreenConfiguration.self, from: data) else {
                return
            }
            let configuredRoots = Set(configuration.displays.values.map {
                URL(fileURLWithPath: $0.renderDirectory).deletingLastPathComponent().standardizedFileURL.path
            })
            let activePath = active.standardizedFileURL.path
            let cutoff = Date().addingTimeInterval(-30)
            for entry in entries {
                let entryPath = entry.standardizedFileURL.path
                guard entryPath != activePath, !configuredRoots.contains(entryPath) else { continue }
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard modified.map({ $0 < cutoff }) ?? true else { continue }
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    private func cleanupDesktopFallbacks() {
        guard let container = sharedContainerURL else { return }
        let directory = container.appendingPathComponent("DynamicLockScreen/DesktopFallbacks", isDirectory: true)
        let configurationURL = configurationURL
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ), let configurationURL,
                  let data = try? Data(contentsOf: configurationURL),
                  let configuration = try? JSONDecoder().decode(
                    DynamicLockScreenConfiguration.self, from: data)
            else { return }
            let keep = Set(configuration.displays.values.compactMap(\.desktopFallbackPath).map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
            for entry in entries where !keep.contains(entry.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    private func registerExtension() {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        let extensionURL = appURL.appendingPathComponent("Contents/Extensions/MirageWallpaperExtension.appex")
        guard FileManager.default.fileExists(atPath: extensionURL.path) else { return }
        DispatchQueue.global(qos: .utility).async {
            let add = Process()
            add.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            add.arguments = ["-a", extensionURL.path]
            try? add.run()
            add.waitUntilExit()
            let enable = Process()
            enable.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            enable.arguments = ["-e", "use", "-i", "cn.laobamac.Mirage.WallpaperExtension"]
            try? enable.run()
            enable.waitUntilExit()
        }
    }

    private func activateStoredConfiguration() {
        guard let configurationURL,
              let data = try? Data(contentsOf: configurationURL),
              var configuration = try? JSONDecoder().decode(
                DynamicLockScreenConfiguration.self, from: data)
        else { return }
        configuration.enabled = true
        guard let updated = try? JSONEncoder().encode(configuration),
              (try? updated.write(to: configurationURL, options: .atomic)) != nil
        else { return }
        refreshDesktopFallbacks()
        notifyConfigurationChanged()
    }

    private func discardUnsupportedConfiguration() {
        guard let url = configurationURL,
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(DynamicLockScreenConfiguration.self, from: data) else { return }
        let supported = !configuration.displays.isEmpty && configuration.displays.values.allSatisfy {
            $0.kind == WallpaperKind.video.rawValue || $0.kind == WallpaperKind.scene.rawValue
        }
        if !supported {
            try? FileManager.default.removeItem(at: url)
            if let container = sharedContainerURL {
                try? FileManager.default.removeItem(at: container.appendingPathComponent("DynamicLockScreen/Deployments", isDirectory: true))
            }
            notifyConfigurationChanged()
        }
    }

    private func notifyConfigurationChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("cn.laobamac.Mirage.dynamicLockScreen.configurationChanged" as CFString),
            nil,
            nil,
            true
        )
    }

    private func notifyDesktopFallbackChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("cn.laobamac.Mirage.dynamicLockScreen.desktopFallbackChanged" as CFString),
            nil,
            nil,
            true
        )
    }
}

enum DynamicLockScreenError: LocalizedError {
    case notEnabled
    case noWallpaper
    case unsupportedWallpaper
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .notEnabled: return L("请先开启动态锁屏并完成确认")
        case .noWallpaper: return L("请先播放一张壁纸")
        case .unsupportedWallpaper: return L("当前壁纸不能用作动态锁屏")
        case .appGroupUnavailable: return L("动态锁屏共享容器不可用")
        }
    }
}
