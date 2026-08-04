//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import SwiftUI
import CoreGraphics

struct WallpaperRuntimeState: Codable, Equatable {
    var volume: Float = 1.0
    var speed: Float = 1.0
    var muted: Bool = false
    var fillMode: FillMode = .cover
    var propertyOverrides: [String: WEPropertyValue] = [:]
}

struct DisplayWallpaperState: Codable, Equatable {
    var wallpaper: WEWallpaper
    var runtime: WallpaperRuntimeState
}

class WallpaperViewModel: ObservableObject {
    let renderer = RendererController()

    private struct AppliedPlaybackState: Equatable {
        let paused: Bool
        let muted: Bool
        let volume: Float
        let speed: Float
        let powerState: MiragePowerState
        let fps: Int
    }

    private static let assignmentsDefaultsKey = "DisplayAssignments"
    private static let selectedDisplayDefaultsKey = "SelectedDisplay"
    private static let legacyWallpaperDefaultsKey = "CurrentWallpaper"

    @Published private(set) var displayStates: [DisplayKey: DisplayWallpaperState] = [:]

    @Published var selectedDisplayKey: DisplayKey {
        didSet {
            guard selectedDisplayKey != oldValue else { return }
            UserDefaults.standard.set(selectedDisplayKey.rawValue,
                                      forKey: Self.selectedDisplayDefaultsKey)
            syncStatusItems()
        }
    }

    @Published var currentByScreen: [Int: WEWallpaper] = [:]

    private var pendingScreenAssignments: [CGDirectDisplayID: UUID] = [:]
    private var lastAppliedPlayback: [DisplayKey: AppliedPlaybackState] = [:]
    private var stoppedByPlaybackPolicy = false
    private var statesSaveWorkItem: DispatchWorkItem?
    private var runtimeSaveWorkItems: [DisplayKey: DispatchWorkItem] = [:]
    private var playbackCommandWorkItems: [DisplayKey: DispatchWorkItem] = [:]
    private var propertyCommandWorkItems: [DisplayKey: DispatchWorkItem] = [:]
    private var pendingPropertyCommands: [DisplayKey: [String: WEProjectProperty]] = [:]
    private var lastVolumeByDisplay: [DisplayKey: Float] = [:]
    private var lastRateByDisplay: [DisplayKey: Float] = [:]

    static var invalidWallpaper: WEWallpaper {
        WEWallpaper(using: .invalid,
                    where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")
                        ?? URL(fileURLWithPath: "/dev/null"))
    }

    init() {
        let registry = DisplayRegistry.shared
        let stored = UserDefaults.standard.string(forKey: Self.selectedDisplayDefaultsKey)
            .map(DisplayKey.init(rawValue:))
        let connectedKeys = registry.connectedKeys
        if let stored, connectedKeys.contains(stored) {
            selectedDisplayKey = stored
        } else {
            selectedDisplayKey = registry.mainKey ?? DisplayKey(rawValue: "idx:0")
        }

        var loaded = Self.loadPersistedStates()
        if loaded.isEmpty, let migrated = Self.loadLegacyState(),
           let mainKey = registry.mainKey {
            loaded[mainKey] = migrated
        }
        displayStates = loaded

        renderer.isWallpaperTrusted = { WallpaperViewModel.isWallpaperTrusted($0) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(displayTopologyChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        persistStates()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: 显示器状态

    var connectedDisplays: [DisplayInfo] {
        DisplayRegistry.shared.connected
    }

    var selectedDisplay: DisplayInfo? {
        DisplayRegistry.shared.info(for: selectedDisplayKey)
    }

    var selectedDisplayName: String {
        DisplayRegistry.shared.displayName(for: selectedDisplayKey)
    }

    var hasAnyWallpaper: Bool {
        !displayStates.isEmpty
    }

    func state(for key: DisplayKey) -> DisplayWallpaperState? {
        displayStates[key]
    }

    func wallpaper(for key: DisplayKey) -> WEWallpaper {
        displayStates[key]?.wallpaper ?? WallpaperViewModel.invalidWallpaper
    }

    func runtime(for key: DisplayKey) -> WallpaperRuntimeState {
        displayStates[key]?.runtime ?? WallpaperRuntimeState()
    }

    func isRendering(_ key: DisplayKey) -> Bool {
        guard let displayID = DisplayRegistry.shared.displayID(for: key) else { return false }
        return renderer.isRendering(onDisplay: displayID)
    }

    // MARK: 选中显示器的门面

    var currentWallpaper: WEWallpaper {
        get { wallpaper(for: selectedDisplayKey) }
        set { assign(newValue, to: selectedDisplayKey) }
    }

    var runtime: WallpaperRuntimeState {
        get { runtime(for: selectedDisplayKey) }
        set {
            guard var state = displayStates[selectedDisplayKey] else { return }
            state.runtime = Self.normalizedRuntime(newValue, for: state.wallpaper)
            displayStates[selectedDisplayKey] = state
            persistStates()
        }
    }

    var playVolume: Float {
        get { runtime(for: selectedDisplayKey).volume }
        set { setVolume(newValue, for: selectedDisplayKey) }
    }

    var playRate: Float {
        get { runtime(for: selectedDisplayKey).speed }
        set { setSpeed(newValue, for: selectedDisplayKey) }
    }

    // MARK: 全局设置桥接

    private var masterVolume: Float {
        Float(AppDelegate.shared.globalSettingsViewModel.settings.masterVolume)
    }
    private var globalMuted: Bool {
        AppDelegate.shared.globalSettingsViewModel.settings.globalMuted
    }
    private var globalFps: Int {
        Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)
    }
    private var enableSpectrum: Bool {
        AppDelegate.shared.globalSettingsViewModel.settings.enableSpectrum
    }
    private var currentPlaybackPolicy: GSPlayback {
        AppDelegate.shared.globalSettingsViewModel.effectivePlaybackAction
    }

    // MARK: 信任（网页壁纸安全确认）

    private static let sessionTrustLock = NSLock()
    nonisolated(unsafe) private static var sessionTrusted: Set<String> = []

    static func trustForSession(_ w: WEWallpaper) {
        sessionTrustLock.lock()
        sessionTrusted.insert(w.id)
        sessionTrustLock.unlock()
    }

    static func clearSessionTrust() {
        sessionTrustLock.lock()
        sessionTrusted.removeAll()
        sessionTrustLock.unlock()
    }

    static func isWallpaperTrusted(_ w: WEWallpaper) -> Bool {
        let list = UserDefaults.standard.stringArray(forKey: "TrustedWallpapers") ?? []
        if list.contains(w.id) { return true }
        sessionTrustLock.lock()
        defer { sessionTrustLock.unlock() }
        return sessionTrusted.contains(w.id)
    }

    func isTrusted(_ w: WEWallpaper) -> Bool {
        WallpaperViewModel.isWallpaperTrusted(w)
    }

    func trust(_ w: WEWallpaper) {
        var list = UserDefaults.standard.stringArray(forKey: "TrustedWallpapers") ?? []
        if !list.contains(w.id) { list.append(w.id) }
        UserDefaults.standard.set(list, forKey: "TrustedWallpapers")
    }

    func trustAndApply(_ w: WEWallpaper) {
        trust(w)
        assign(w, to: selectedDisplayKey)
    }

    func requestApply(_ wallpaper: WEWallpaper) {
        requestApply(wallpaper, to: selectedDisplayKey)
    }

    func requestApply(_ wallpaper: WEWallpaper, to key: DisplayKey) {
        guard wallpaper.isValid, wallpaper.kind != .unsupported else { return }
        if wallpaper.kind == .web, !isTrusted(wallpaper) {
            guard let displayID = DisplayRegistry.shared.displayID(for: key) else { return }
            AppDelegate.shared.contentViewModel.warningUnsafeWallpaperModal(
                which: wallpaper, action: .applyOnDisplay(displayID))
            return
        }
        assign(wallpaper, to: key)
    }

    // MARK: 指派与停止

    func assign(_ wallpaper: WEWallpaper, to key: DisplayKey) {
        guard wallpaper.isValid, wallpaper.kind != .unsupported else {
            clear(key)
            return
        }
        let previous = displayStates[key]
        if let previous, previous.wallpaper.id != wallpaper.id {
            cancelRuntimeSave(for: key)
            persistRuntime(previous.runtime, for: previous.wallpaper)
        }
        let resolved: WallpaperRuntimeState
        if let previous, previous.wallpaper.id == wallpaper.id {
            resolved = previous.runtime
        } else {
            resolved = Self.loadPersistedRuntime(for: wallpaper)
        }
        let state = DisplayWallpaperState(wallpaper: wallpaper, runtime: resolved)
        displayStates[key] = state
        lastAppliedPlayback[key] = nil
        persistStates()
        cancelPendingProperties(for: key)

        guard let displayID = DisplayRegistry.shared.displayID(for: key) else {
            syncStatusItems()
            return
        }
        if currentPlaybackPolicy == .stop {
            pendingScreenAssignments[displayID] = nil
            commit(state, to: displayID, key: key)
        } else {
            apply(state, to: displayID, key: key, reuseActive: true)
        }
        applyPlaybackPolicy(currentPlaybackPolicy, for: key, force: true)
        syncStatusItems()
    }

    func applyOnDisplay(_ w: WEWallpaper, displayID targetDisplayID: CGDirectDisplayID) {
        guard let key = DisplayRegistry.shared.key(forDisplay: targetDisplayID) else { return }
        assign(w, to: key)
    }

    func applyOnScreen(_ w: WEWallpaper, screen: Int) {
        guard let key = DisplayRegistry.shared.key(forScreenIndex: screen) else { return }
        assign(w, to: key)
    }

    func applyToAllDisplays(_ w: WEWallpaper) {
        guard w.isValid, w.kind != .unsupported else { return }
        for info in DisplayRegistry.shared.connected {
            assign(w, to: info.key)
        }
    }

    func applyToAllScreens() {
        guard let state = displayStates[selectedDisplayKey] else { return }
        applyToAllDisplays(state.wallpaper)
    }

    func clear(_ key: DisplayKey) {
        if let state = displayStates[key] {
            cancelRuntimeSave(for: key)
            persistRuntime(state.runtime, for: state.wallpaper)
        }
        displayStates[key] = nil
        lastAppliedPlayback[key] = nil
        cancelPendingProperties(for: key)
        persistStates()
        if let index = DisplayRegistry.shared.screenIndex(for: key) {
            currentByScreen[index] = nil
        }
        if let displayID = DisplayRegistry.shared.displayID(for: key) {
            pendingScreenAssignments[displayID] = nil
            renderer.stop(displayID: displayID)
        }
        syncStatusItems()
    }

    func stopWallpaper() {
        clear(selectedDisplayKey)
    }

    func stopAllWallpapers() {
        for (key, state) in displayStates {
            cancelRuntimeSave(for: key)
            persistRuntime(state.runtime, for: state.wallpaper)
            cancelPendingProperties(for: key)
        }
        renderer.stopAll()
        pendingScreenAssignments.removeAll()
        displayStates.removeAll()
        lastAppliedPlayback.removeAll()
        currentByScreen.removeAll()
        stoppedByPlaybackPolicy = false
        persistStates()
        syncStatusItems()
    }

    func removeWallpaper(at directory: URL) {
        let identifier = directory.path(percentEncoded: false)
        let targets = displayStates.filter { $0.value.wallpaper.id == identifier }.map(\.key)
        for key in targets { clear(key) }
    }

    // MARK: 渲染

    func restoreAllDisplays() {
        guard currentPlaybackPolicy != .stop else { return }
        for info in DisplayRegistry.shared.connected {
            guard let state = displayStates[info.key] else { continue }
            apply(state, to: info.displayID, key: info.key, reuseActive: false)
            DesktopOverrideService.shared.scheduleCapture(
                forDisplay: info.displayID, wallpaper: state.wallpaper)
        }
        applyPlaybackPolicy(currentPlaybackPolicy, force: true)
        syncStatusItems()
    }

    func reapply(for key: DisplayKey) {
        guard let state = displayStates[key],
              let displayID = DisplayRegistry.shared.displayID(for: key) else { return }
        cancelPendingProperties(for: key)
        if currentPlaybackPolicy != .stop {
            apply(state, to: displayID, key: key, reuseActive: false)
        }
        applyPlaybackPolicy(currentPlaybackPolicy, for: key, force: true)
    }

    func reapplyCurrent() {
        reapply(for: selectedDisplayKey)
    }

    private func apply(_ state: DisplayWallpaperState, to displayID: CGDirectDisplayID,
                       key: DisplayKey, reuseActive: Bool) {
        let options = makeRenderOptions(for: state.wallpaper, runtime: state.runtime)
        let requestID = UUID()
        pendingScreenAssignments[displayID] = requestID
        let accepted = renderer.render(
            state.wallpaper,
            onDisplay: displayID,
            options: options,
            reuseActive: reuseActive
        ) { [weak self] success in
            guard let self,
                  self.pendingScreenAssignments[displayID] == requestID else { return }
            self.pendingScreenAssignments[displayID] = nil
            guard success else { return }
            self.commit(state, to: displayID, key: key)
        }
        if !accepted, pendingScreenAssignments[displayID] == requestID {
            pendingScreenAssignments[displayID] = nil
        }
    }

    private func commit(_ state: DisplayWallpaperState, to displayID: CGDirectDisplayID,
                        key: DisplayKey) {
        if let index = DisplayRegistry.shared.screenIndex(for: key) {
            currentByScreen[index] = state.wallpaper
        }
        DesktopOverrideService.shared.scheduleCapture(
            forDisplay: displayID, wallpaper: state.wallpaper)
    }

    private func makeRenderOptions(for w: WEWallpaper,
                                   runtime state: WallpaperRuntimeState) -> RenderOptions {
        let settings = AppDelegate.shared.globalSettingsViewModel.settings
        var opts = RenderOptions()
        opts.fps = globalFps
        opts.enableSpectrum = enableSpectrum
        opts.muted = state.muted || globalMuted || state.volume == 0 || currentPlaybackPolicy == .mute
        opts.volume = state.volume * masterVolume
        opts.speed = state.speed
        opts.fillMode = state.fillMode
        opts.userProperties = effectiveProperties(for: w, runtime: state)
        opts.loadFromMemory = (settings.wallpaperLoadSource ?? .disk) == .memory
        switch settings.textureResolution {
        case .highQuality: opts.renderScale = 1.0
        case .automatic: opts.renderScale = 0.75
        case .highPerformance: opts.renderScale = 0.5
        }
        switch settings.antiAliasing {
        case .none: opts.msaaSamples = 1
        case .msaa_x2: opts.msaaSamples = 2
        case .msaa_x4: opts.msaaSamples = 4
        case .msaa_x8: opts.msaaSamples = 8
        }
        return opts
    }

    // MARK: 拓扑变化

    @objc private func displayTopologyChanged() {
        DisplayRegistry.shared.invalidate()
        let connected = DisplayRegistry.shared.connected
        let connectedIDs = Set(connected.map(\.displayID))
        let connectedKeys = Set(connected.map(\.key))

        renderer.stopDisplays(except: connectedIDs)
        pendingScreenAssignments = pendingScreenAssignments.filter { connectedIDs.contains($0.key) }
        lastAppliedPlayback = lastAppliedPlayback.filter { connectedKeys.contains($0.key) }

        if !connectedKeys.contains(selectedDisplayKey) {
            selectedDisplayKey = DisplayRegistry.shared.mainKey
                ?? connected.first?.key ?? selectedDisplayKey
        }

        let inherited = DisplayRegistry.shared.mainKey.flatMap { displayStates[$0] }
            ?? displayStates[selectedDisplayKey]
        var seeded = false
        for info in connected {
            if displayStates[info.key] == nil, let inherited {
                displayStates[info.key] = inherited
                lastAppliedPlayback[info.key] = nil
                seeded = true
            }
            guard let state = displayStates[info.key] else { continue }
            if currentPlaybackPolicy != .stop {
                apply(state, to: info.displayID, key: info.key, reuseActive: true)
            }
        }
        if seeded { persistStates() }

        var rebuilt: [Int: WEWallpaper] = [:]
        for info in connected {
            guard let state = displayStates[info.key] else { continue }
            rebuilt[info.index] = state.wallpaper
        }
        currentByScreen = rebuilt

        DesktopOverrideService.shared.scheduleCaptureForAllScreens()
        if !stoppedByPlaybackPolicy {
            applyPlaybackPolicy(currentPlaybackPolicy, force: true)
        }
        syncStatusItems()
    }

    // MARK: 运行时状态持久化

    private static func runtimeKey(for w: WEWallpaper) -> String { "Runtime_\(w.id)" }

    func loadRuntime(for w: WEWallpaper) -> WallpaperRuntimeState {
        Self.loadPersistedRuntime(for: w)
    }

    private static func loadPersistedRuntime(for w: WEWallpaper) -> WallpaperRuntimeState {
        if let data = UserDefaults.standard.data(forKey: runtimeKey(for: w)),
           let saved = try? JSONDecoder().decode(WallpaperRuntimeState.self, from: data) {
            let normalized = normalizedRuntime(saved, for: w)
            if normalized != saved, let migrated = try? JSONEncoder().encode(normalized) {
                UserDefaults.standard.set(migrated, forKey: runtimeKey(for: w))
            }
            return normalized
        }
        return WallpaperRuntimeState()
    }

    func saveRuntime() {
        if var state = displayStates[selectedDisplayKey] {
            let normalized = Self.normalizedRuntime(state.runtime, for: state.wallpaper)
            if normalized != state.runtime {
                state.runtime = normalized
                displayStates[selectedDisplayKey] = state
            }
        }
        for (key, state) in displayStates {
            cancelRuntimeSave(for: key)
            persistRuntime(state.runtime, for: state.wallpaper)
        }
        persistStates()
    }

    private func persistRuntime(_ state: WallpaperRuntimeState, for wallpaper: WEWallpaper) {
        guard wallpaper.isValid else { return }
        let normalized = Self.normalizedRuntime(state, for: wallpaper)
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: Self.runtimeKey(for: wallpaper))
        if ScreenSaverManager.shared.configuredWallpaperID() == wallpaper.id {
            try? ScreenSaverManager.shared.configure(
                with: wallpaper,
                runtime: normalized,
                properties: effectiveProperties(for: wallpaper, runtime: normalized),
                fps: Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)
            )
        }
    }

    private func scheduleRuntimeSave(for key: DisplayKey) {
        runtimeSaveWorkItems[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.runtimeSaveWorkItems[key] = nil
            guard let state = self.displayStates[key] else { return }
            self.persistRuntime(state.runtime, for: state.wallpaper)
        }
        runtimeSaveWorkItems[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelRuntimeSave(for key: DisplayKey) {
        runtimeSaveWorkItems[key]?.cancel()
        runtimeSaveWorkItems[key] = nil
    }

    private func persistStates() {
        statesSaveWorkItem?.cancel()
        statesSaveWorkItem = nil
        writeStates()
    }

    private func scheduleStatesSave() {
        statesSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statesSaveWorkItem = nil
            self.writeStates()
        }
        statesSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func writeStates() {
        var raw: [String: DisplayWallpaperState] = [:]
        for (key, state) in displayStates {
            raw[key.rawValue] = state
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.assignmentsDefaultsKey)
        }
        let mainState = DisplayRegistry.shared.mainKey.flatMap { displayStates[$0] }
        if let mainState, let data = try? JSONEncoder().encode(mainState.wallpaper) {
            UserDefaults.standard.set(data, forKey: Self.legacyWallpaperDefaultsKey)
        } else if mainState == nil {
            UserDefaults.standard.removeObject(forKey: Self.legacyWallpaperDefaultsKey)
        }
    }

    private static func loadPersistedStates() -> [DisplayKey: DisplayWallpaperState] {
        guard let data = UserDefaults.standard.data(forKey: assignmentsDefaultsKey),
              let raw = try? JSONDecoder().decode([String: DisplayWallpaperState].self, from: data)
        else { return [:] }
        var result: [DisplayKey: DisplayWallpaperState] = [:]
        for (rawKey, stored) in raw {
            guard FileManager.default.fileExists(
                atPath: stored.wallpaper.wallpaperDirectory.path) else { continue }
            let refreshed = WEWallpaper.load(from: stored.wallpaper.wallpaperDirectory)
            guard refreshed.isValid, refreshed.kind != .unsupported else { continue }
            result[DisplayKey(rawValue: rawKey)] = DisplayWallpaperState(
                wallpaper: refreshed,
                runtime: normalizedRuntime(stored.runtime, for: refreshed))
        }
        return result
    }

    private static func loadLegacyState() -> DisplayWallpaperState? {
        guard let data = UserDefaults.standard.data(forKey: legacyWallpaperDefaultsKey),
              let stored = try? JSONDecoder().decode(WEWallpaper.self, from: data),
              FileManager.default.fileExists(atPath: stored.wallpaperDirectory.path)
        else { return nil }
        let refreshed = WEWallpaper.load(from: stored.wallpaperDirectory)
        guard refreshed.isValid, refreshed.kind != .unsupported else { return nil }
        return DisplayWallpaperState(wallpaper: refreshed,
                                     runtime: loadPersistedRuntime(for: refreshed))
    }

    // MARK: 属性合并

    func effectiveProperties(for w: WEWallpaper) -> [String: WEProjectProperty] {
        effectiveProperties(for: w, runtime: runtime(for: selectedDisplayKey))
    }

    func effectiveProperties(for w: WEWallpaper,
                             runtime runtimeState: WallpaperRuntimeState) -> [String: WEProjectProperty] {
        var result = w.project.general?.properties?.items ?? [:]
        for (key, override) in runtimeState.propertyOverrides {
            if var prop = result[key] {
                prop.value = prop.normalizedComboValue(override)
                result[key] = prop
            }
        }
        if !w.assetOverlayDirectories.isEmpty {
            let baseProperties = loadBaseProperties(for: w)
            let presetKeys = Set(w.project.preset?.keys.map { $0 } ?? [])
            for (key, var property) in result where property.propertyType == .file ||
                property.propertyType == .scenetexture || property.propertyType == .directory {
                let path = property.value.stringValue
                guard !path.isEmpty else { continue }
                if isWindowsAbsolutePath(path) || ((path as NSString).isAbsolutePath &&
                    !FileManager.default.fileExists(atPath: path)) {
                    if presetKeys.contains(key), let fallback = baseProperties[key]?.value {
                        property.value = fallback
                        result[key] = property
                    }
                } else if !(path as NSString).isAbsolutePath,
                          let resolved = resolvedPresetAsset(path, in: w.assetOverlayDirectories) {
                    property.value = .string(resolved.path)
                    result[key] = property
                } else if !(path as NSString).isAbsolutePath,
                          presetKeys.contains(key), path.hasPrefix("files/"),
                          let fallback = baseProperties[key]?.value {
                    property.value = fallback
                    result[key] = property
                }
            }
        }
        return result
    }

    private static func normalizedRuntime(_ source: WallpaperRuntimeState,
                                          for wallpaper: WEWallpaper) -> WallpaperRuntimeState {
        var result = source
        let properties = wallpaper.project.general?.properties?.items ?? [:]
        for (key, value) in result.propertyOverrides {
            guard let property = properties[key] else { continue }
            result.propertyOverrides[key] = property.normalizedComboValue(value)
        }
        return result
    }

    private func loadBaseProperties(for wallpaper: WEWallpaper) -> [String: WEProjectProperty] {
        let url = wallpaper.renderDirectory.appending(path: "project.json")
        guard let data = try? Data(contentsOf: url),
              let project = try? JSONDecoder().decode(WEProject.self, from: data) else { return [:] }
        return project.general?.properties?.items ?? [:]
    }

    private func isWindowsAbsolutePath(_ path: String) -> Bool {
        path.range(of: "^[A-Za-z]:[\\\\/]", options: .regularExpression) != nil
    }

    private func resolvedPresetAsset(_ relativePath: String, in directories: [URL]) -> URL? {
        for directory in directories {
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            let candidate = root.appending(path: relativePath).standardizedFileURL.resolvingSymlinksInPath()
            let isInside = candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
            if isInside, FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: 属性实时下发

    func setProperty(key: String, value: WEPropertyValue) {
        setProperty(key: key, value: value, for: selectedDisplayKey)
    }

    func setProperty(key propertyKey: String, value: WEPropertyValue, for displayKey: DisplayKey) {
        guard let state = displayStates[displayKey],
              var prop = state.wallpaper.project.general?.properties?.items[propertyKey] else { return }
        let normalizedValue = prop.normalizedComboValue(value)
        prop.value = normalizedValue
        mutateRuntime(for: displayKey) { $0.propertyOverrides[propertyKey] = normalizedValue }

        switch state.wallpaper.kind {
        case .web, .scene:
            pendingPropertyCommands[displayKey, default: [:]][propertyKey] = prop
            propertyCommandWorkItems[displayKey]?.cancel()
            let wallpaperID = state.wallpaper.id
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.propertyCommandWorkItems[displayKey] = nil
                let commands = self.pendingPropertyCommands.removeValue(forKey: displayKey) ?? [:]
                guard self.displayStates[displayKey]?.wallpaper.id == wallpaperID,
                      let displayID = DisplayRegistry.shared.displayID(for: displayKey) else { return }
                for (key, property) in commands {
                    self.renderer.setProperty(key: key, property: property, onDisplay: displayID)
                }
            }
            propertyCommandWorkItems[displayKey] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: work)
        case .video, .unsupported:
            break
        }
    }

    private func cancelPendingProperties(for key: DisplayKey) {
        propertyCommandWorkItems[key]?.cancel()
        propertyCommandWorkItems[key] = nil
        pendingPropertyCommands[key] = nil
    }

    func setFillMode(_ mode: FillMode) {
        setFillMode(mode, for: selectedDisplayKey)
    }

    func setFillMode(_ mode: FillMode, for key: DisplayKey) {
        guard displayStates[key] != nil else { return }
        mutateRuntime(for: key) { $0.fillMode = mode }
        guard let displayID = DisplayRegistry.shared.displayID(for: key) else { return }
        renderer.setFillMode(mode, onDisplay: displayID)
    }

    func resetProperties() {
        let key = selectedDisplayKey
        guard var state = displayStates[key] else { return }
        state.runtime = WallpaperRuntimeState()
        displayStates[key] = state
        lastAppliedPlayback[key] = nil
        persistStates()
        cancelRuntimeSave(for: key)
        persistRuntime(state.runtime, for: state.wallpaper)
        reapply(for: key)
        syncStatusItems()
    }

    // MARK: 播放控制

    private func mutateRuntime(for key: DisplayKey,
                               _ transform: (inout WallpaperRuntimeState) -> Void) {
        guard var state = displayStates[key] else { return }
        transform(&state.runtime)
        displayStates[key] = state
        scheduleStatesSave()
        scheduleRuntimeSave(for: key)
    }

    func setVolume(_ value: Float, for key: DisplayKey) {
        guard displayStates[key] != nil else { return }
        lastVolumeByDisplay[key] = runtime(for: key).volume
        mutateRuntime(for: key) { $0.volume = value }
        schedulePlaybackPolicyApplication(for: key)
        syncStatusItems()
    }

    func setSpeed(_ value: Float, for key: DisplayKey) {
        guard displayStates[key] != nil else { return }
        lastRateByDisplay[key] = runtime(for: key).speed
        mutateRuntime(for: key) { $0.speed = value }
        schedulePlaybackPolicyApplication(for: key)
        syncStatusItems()
    }

    func muteAll() {
        for key in Array(displayStates.keys) { setVolume(0, for: key) }
    }

    func unmuteAll() {
        for key in Array(displayStates.keys) {
            let remembered = lastVolumeByDisplay[key] ?? 1
            setVolume(remembered == 0 ? 1 : remembered, for: key)
        }
    }

    func pauseAll() {
        for key in Array(displayStates.keys) { setSpeed(0, for: key) }
    }

    func resumeAll() {
        for key in Array(displayStates.keys) {
            let remembered = lastRateByDisplay[key] ?? 1
            setSpeed(remembered == 0 ? 1 : remembered, for: key)
        }
    }

    private func schedulePlaybackPolicyApplication(for key: DisplayKey) {
        playbackCommandWorkItems[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.playbackCommandWorkItems[key] = nil
            self.applyPlaybackPolicy(self.currentPlaybackPolicy, for: key)
        }
        playbackCommandWorkItems[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: work)
    }

    func reapplyVolume() {
        applyPlaybackPolicy(currentPlaybackPolicy)
    }

    func reapplyFrameRate() {
        applyPlaybackPolicy(currentPlaybackPolicy, force: true)
    }

    func applyPlaybackPolicy(_ action: GSPlayback, force: Bool = false) {
        if action == .stop {
            if !stoppedByPlaybackPolicy {
                renderer.stopAll()
                stoppedByPlaybackPolicy = true
            }
            lastAppliedPlayback.removeAll()
            return
        }

        if stoppedByPlaybackPolicy {
            stoppedByPlaybackPolicy = false
            lastAppliedPlayback.removeAll()
            for info in DisplayRegistry.shared.connected {
                guard let state = displayStates[info.key] else { continue }
                apply(state, to: info.displayID, key: info.key, reuseActive: true)
            }
        }

        for info in DisplayRegistry.shared.connected {
            applyPlaybackPolicy(action, for: info.key, force: force)
        }
    }

    private func applyPlaybackPolicy(_ action: GSPlayback, for key: DisplayKey,
                                     force: Bool = false) {
        guard let displayID = DisplayRegistry.shared.displayID(for: key),
              let state = displayStates[key] else { return }
        if action == .stop {
            renderer.stop(displayID: displayID)
            lastAppliedPlayback[key] = nil
            return
        }

        let runtimeState = state.runtime
        let throttledFps = AppDelegate.shared.globalSettingsViewModel.throttledFps(base: globalFps)
        let paused = runtimeState.speed == 0 || action == .pause
        let powerState: MiragePowerState = paused ? .pause
            : (throttledFps < globalFps ? .throttle : .run)

        let applied = AppliedPlaybackState(
            paused: paused,
            muted: runtimeState.muted || globalMuted || runtimeState.volume == 0 || action == .mute,
            volume: runtimeState.volume * masterVolume,
            speed: runtimeState.speed,
            powerState: powerState,
            fps: throttledFps
        )
        guard force || applied != lastAppliedPlayback[key] else { return }

        if applied.paused {
            renderer.setPower(applied.powerState, fps: applied.fps, onDisplay: displayID)
            renderer.setVolume(applied.volume, onDisplay: displayID)
            renderer.setMuted(applied.muted, onDisplay: displayID)
        } else {
            renderer.setVolume(applied.volume, onDisplay: displayID)
            renderer.setMuted(applied.muted, onDisplay: displayID)
            renderer.setSpeed(applied.speed, onDisplay: displayID)
            renderer.setPower(applied.powerState, fps: applied.fps, onDisplay: displayID)
        }
        lastAppliedPlayback[key] = applied
    }

    // MARK: 状态栏菜单项文字同步

    private func syncStatusItems() {
        let active = displayStates.filter { DisplayRegistry.shared.displayID(for: $0.key) != nil }
        let muted = !active.isEmpty && active.values.allSatisfy {
            $0.runtime.muted || $0.runtime.volume == 0
        }
        let paused = !active.isEmpty && active.values.allSatisfy { $0.runtime.speed == 0 }
        syncStatusPauseItem(isPaused: paused)
        syncStatusMuteItem(isMuted: muted)
    }

    private func syncStatusPauseItem(isPaused: Bool) {
        guard let menu = AppDelegate.shared.statusItem?.menu else { return }
        let pauseTitle = L("暂停")
        let resumeTitle = L("继续")
        for item in menu.items {
            if isPaused, item.title == pauseTitle {
                item.title = resumeTitle
                item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
                item.action = #selector(AppDelegate.resume)
                item.target = AppDelegate.shared
            } else if !isPaused, item.title == resumeTitle {
                item.title = pauseTitle
                item.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
                item.action = #selector(AppDelegate.pause)
                item.target = AppDelegate.shared
            }
        }
    }

    private func syncStatusMuteItem(isMuted: Bool) {
        guard let menu = AppDelegate.shared.statusItem?.menu else { return }
        let muteTitle = L("静音")
        let unmuteTitle = L("取消静音")
        for (i, item) in menu.items.enumerated() {
            if isMuted, item.title == muteTitle {
                let replacement = NSMenuItem(title: unmuteTitle, systemImage: "speaker.fill",
                                             action: #selector(AppDelegate.unmute), keyEquivalent: "")
                replacement.target = AppDelegate.shared
                menu.items[i] = replacement
            } else if !isMuted, item.title == unmuteTitle {
                let replacement = NSMenuItem(title: muteTitle, systemImage: "speaker.slash.fill",
                                             action: #selector(AppDelegate.mute), keyEquivalent: "")
                replacement.target = AppDelegate.shared
                menu.items[i] = replacement
            }
        }
    }
}
