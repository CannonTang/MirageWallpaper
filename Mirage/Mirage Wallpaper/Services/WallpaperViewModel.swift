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

class WallpaperViewModel: ObservableObject {
    let renderer = RendererController()

    private struct ScreenAssignment {
        let wallpaper: WEWallpaper
        let runtime: WallpaperRuntimeState
    }

    private struct AppliedPlaybackState: Equatable {
        let paused: Bool
        let muted: Bool
        let volume: Float
        let speed: Float
        let powerState: MiragePowerState
        let fps: Int
    }

    private var lastAppliedPlaybackState: AppliedPlaybackState?
    private var screenAssignments: [CGDirectDisplayID: ScreenAssignment] = [:]
    private var pendingScreenAssignments: [CGDirectDisplayID: UUID] = [:]
    private var stoppedByPlaybackPolicy = false
    private var runtimeSaveWorkItem: DispatchWorkItem?
    private var playbackCommandWorkItem: DispatchWorkItem?
    private var propertyCommandWorkItem: DispatchWorkItem?
    private var pendingPropertyCommands: [String: WEProjectProperty] = [:]

    static var invalidWallpaper: WEWallpaper {
        WEWallpaper(using: .invalid,
                    where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")
                        ?? URL(fileURLWithPath: "/dev/null"))
    }

    /// Entry point for "user picked this wallpaper in the UI". Web wallpapers
    /// run untrusted third-party JS, so an unconfirmed one is routed to the
    /// trust sheet instead of being applied.
    ///
    /// This used to be a `@Published var nextCurrentWallpaper` whose `willSet`
    /// either presented the sheet or assigned `currentWallpaper`. Mutating one
    /// published property from inside another's `willSet` is exactly what
    /// triggers SwiftUI's "Publishing changes from within view updates", and
    /// the sheet read the new value back before `willSet` had committed it.
    func requestApply(_ wallpaper: WEWallpaper) {
        guard wallpaper.isValid, wallpaper.kind != .unsupported else { return }
        if wallpaper.kind == .web, !isTrusted(wallpaper) {
            AppDelegate.shared.contentViewModel.warningUnsafeWallpaperModal(which: wallpaper)
            return
        }
        currentWallpaper = wallpaper
    }

    @Published var currentWallpaper: WEWallpaper {
        didSet {
            if oldValue.isValid, oldValue.id != currentWallpaper.id {
                runtimeSaveWorkItem?.cancel()
                runtimeSaveWorkItem = nil
                persistRuntime(runtime, for: oldValue)
            }
            UserDefaults.standard.set(try? JSONEncoder().encode(currentWallpaper), forKey: "CurrentWallpaper")
            applyCurrent()
            currentByScreen[0] = currentWallpaper.isValid ? currentWallpaper : nil
        }
    }

    @Published var currentByScreen: [Int: WEWallpaper] = [:]

    @Published var runtime = WallpaperRuntimeState()

    // 避免运行时回填 UI 时重复下发指令。
    private var suppressPlaybackSideEffects = false

    var lastPlayRate: Float = 1.0
    @Published var playRate: Float = 1.0 {
        willSet { syncStatusPauseItem(isPaused: newValue == 0.0) }
        didSet {
            lastPlayRate = oldValue
            guard !suppressPlaybackSideEffects else { return }
            runtime.speed = playRate
            schedulePlaybackPolicyApplication()
            scheduleRuntimeSave()
        }
    }

    var lastPlayVolume: Float = 1.0
    @Published var playVolume: Float = 1.0 {
        willSet { syncStatusMuteItem(isMuted: newValue == 0.0) }
        didSet {
            lastPlayVolume = oldValue
            guard !suppressPlaybackSideEffects else { return }
            runtime.volume = playVolume
            schedulePlaybackPolicyApplication()
            scheduleRuntimeSave()
        }
    }

    init() {
        if let json = UserDefaults.standard.data(forKey: "CurrentWallpaper"),
           let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: json),
           FileManager.default.fileExists(atPath: wallpaper.wallpaperDirectory.path) {
            currentWallpaper = WEWallpaper.load(from: wallpaper.wallpaperDirectory)
        } else {
            currentWallpaper = WallpaperViewModel.invalidWallpaper
        }
        // Silent backstop. `requestApply` above remains the thing that prompts
        // the user; this makes sure an unconfirmed web wallpaper can never be
        // spawned by one of the many paths that assign currentWallpaper directly
        // (playlist rotation, per-screen apply, launch restore). Deliberately a
        // context-free closure, so the renderer holds nothing of `self`.
        renderer.isWallpaperTrusted = { WallpaperViewModel.isWallpaperTrusted($0) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(displayTopologyChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    /// Wallpapers the user confirmed in the trust sheet without ticking "don't
    /// ask again". Without this, "继续" had nowhere to record the user's consent:
    /// `RendererController`'s trust backstop consults the persisted list only,
    /// so a one-shot confirmation was vetoed by that backstop and the wallpaper
    /// silently never launched. Session-scoped on purpose — consent lasts until
    /// Mirage quits, whereas the checkbox persists it across launches.
    ///
    /// `static` to match `isWallpaperTrusted` below: the closure handed to
    /// `RendererController` stays context-free and retains nothing.
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

    /// The trust store is plain UserDefaults state, so it is exposed as a type
    /// method: `RendererController` consults it through an injected closure and
    /// never needs (or retains) a reference to the view model.
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
        currentWallpaper = w
    }

    // MARK: 运行时状态持久化

    private func runtimeKey(for w: WEWallpaper) -> String { "Runtime_\(w.id)" }

    func loadRuntime(for w: WEWallpaper) -> WallpaperRuntimeState {
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
        guard currentWallpaper.isValid else { return }
        let normalized = normalizedRuntime(runtime, for: currentWallpaper)
        if normalized != runtime { runtime = normalized }
        if let displayID = displayID(for: 0) {
            screenAssignments[displayID] = ScreenAssignment(
                wallpaper: currentWallpaper, runtime: normalized)
        }
        persistRuntime(normalized, for: currentWallpaper)
    }

    private func persistRuntime(_ state: WallpaperRuntimeState, for wallpaper: WEWallpaper) {
        let normalized = normalizedRuntime(state, for: wallpaper)
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: runtimeKey(for: wallpaper))
        if ScreenSaverManager.shared.configuredWallpaperID() == wallpaper.id {
            try? ScreenSaverManager.shared.configure(
                with: wallpaper,
                runtime: normalized,
                properties: effectiveProperties(for: wallpaper, runtime: normalized),
                fps: Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)
            )
        }
    }

    private func scheduleRuntimeSave() {
        runtimeSaveWorkItem?.cancel()
        let wallpaper = currentWallpaper
        let state = runtime
        let work = DispatchWorkItem { [weak self] in
            self?.persistRuntime(state, for: wallpaper)
        }
        runtimeSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func schedulePlaybackPolicyApplication() {
        playbackCommandWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyPlaybackPolicy(self.currentPlaybackPolicy)
        }
        playbackCommandWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: work)
    }

    // MARK: 属性合并

    func effectiveProperties(for w: WEWallpaper) -> [String: WEProjectProperty] {
        effectiveProperties(for: w, runtime: runtime)
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
        // A workshop preset may store file/directory values relative to its
        // own overlay (for example "files/background.jpg"). Resolve those
        // for both scene and web dependencies: many legacy web wallpapers
        // prepend file:/// themselves and therefore cannot use a bare path
        // relative to the dependency's entry page.
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

    private func normalizedRuntime(_ source: WallpaperRuntimeState,
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

    private func makeRenderOptions(for w: WEWallpaper,
                                   runtime runtimeState: WallpaperRuntimeState? = nil) -> RenderOptions {
        let state = runtimeState ?? runtime
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

    private func displayID(for screenIndex: Int) -> CGDirectDisplayID? {
        renderer.displayID(for: screenIndex)
    }

    private func apply(_ assignment: ScreenAssignment,
                       to displayID: CGDirectDisplayID,
                       options: RenderOptions) {
        if currentPlaybackPolicy == .stop {
            pendingScreenAssignments[displayID] = nil
            commit(assignment, to: displayID)
            return
        }
        let requestID = UUID()
        pendingScreenAssignments[displayID] = requestID
        let accepted = renderer.render(
            assignment.wallpaper,
            onDisplay: displayID,
            options: options,
            reuseActive: true
        ) { [weak self] success in
            guard let self,
                  self.pendingScreenAssignments[displayID] == requestID else { return }
            self.pendingScreenAssignments[displayID] = nil
            guard success else { return }
            self.commit(assignment, to: displayID)
        }
        if !accepted, pendingScreenAssignments[displayID] == requestID {
            pendingScreenAssignments[displayID] = nil
        }
    }

    private func commit(_ assignment: ScreenAssignment,
                        to displayID: CGDirectDisplayID) {
        guard let screenIndex = renderer.screenIndex(for: displayID) else { return }
        screenAssignments[displayID] = assignment
        currentByScreen[screenIndex] = assignment.wallpaper
        DesktopOverrideService.shared.scheduleCapture(
            forDisplay: displayID, wallpaper: assignment.wallpaper)
    }

    @objc private func displayTopologyChanged() {
        let displayIDs = Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value
        })
        renderer.stopDisplays(except: displayIDs)
        pendingScreenAssignments = pendingScreenAssignments.filter {
            displayIDs.contains($0.key)
        }
        screenAssignments = screenAssignments.filter { displayIDs.contains($0.key) }

        if let mainDisplayID = displayID(for: 0) {
            let inherited = screenAssignments[mainDisplayID] ?? (currentWallpaper.isValid
                ? ScreenAssignment(wallpaper: currentWallpaper, runtime: runtime)
                : nil)
            if let inherited {
                for displayID in displayIDs where screenAssignments[displayID] == nil {
                    apply(inherited, to: displayID,
                          options: makeRenderOptions(for: inherited.wallpaper,
                                                     runtime: inherited.runtime))
                }
            }
        }

        currentByScreen = Dictionary(uniqueKeysWithValues: screenAssignments.compactMap { displayID, assignment in
            renderer.screenIndex(for: displayID).map { ($0, assignment.wallpaper) }
        })
        DesktopOverrideService.shared.scheduleCaptureForAllScreens()
        if !stoppedByPlaybackPolicy {
            applyPlaybackPolicy(currentPlaybackPolicy, force: true)
        }
    }

    // MARK: 应用壁纸

    private func applyCurrent() {
        propertyCommandWorkItem?.cancel()
        pendingPropertyCommands.removeAll(keepingCapacity: true)
        let w = currentWallpaper
        guard w.isValid, w.kind != .unsupported else {
            renderer.stopAll()
            screenAssignments.removeAll()
            return
        }
        runtime = loadRuntime(for: w)
        suppressPlaybackSideEffects = true
        playVolume = runtime.volume
        playRate = runtime.speed
        suppressPlaybackSideEffects = false
        let opts = makeRenderOptions(for: w)
        guard let displayID = displayID(for: 0) else { return }
        screenAssignments[displayID] = ScreenAssignment(wallpaper: w, runtime: runtime)
        if currentPlaybackPolicy != .stop {
            renderer.render(w, onDisplay: displayID, options: opts)
        }
        applyPlaybackPolicy(currentPlaybackPolicy, force: true)
        DesktopOverrideService.shared.scheduleCapture(forDisplay: displayID, wallpaper: w)
    }

    func reapplyCurrent() {
        propertyCommandWorkItem?.cancel()
        pendingPropertyCommands.removeAll(keepingCapacity: true)
        let w = currentWallpaper
        guard w.isValid else { return }
        runtime = loadRuntime(for: w)
        suppressPlaybackSideEffects = true
        playVolume = runtime.volume
        playRate = runtime.speed
        suppressPlaybackSideEffects = false
        guard let displayID = displayID(for: 0) else { return }
        screenAssignments[displayID] = ScreenAssignment(wallpaper: w, runtime: runtime)
        if currentPlaybackPolicy != .stop {
            renderer.render(w, onDisplay: displayID, options: makeRenderOptions(for: w))
        }
        applyPlaybackPolicy(currentPlaybackPolicy, force: true)
    }

    func applyToAllScreens() {
        let w = currentWallpaper
        guard w.isValid, w.kind != .unsupported else { return }
        currentWallpaper = w
        for screen in NSScreen.screens.indices.dropFirst() {
            guard let displayID = displayID(for: screen) else { continue }
            var opts = makeRenderOptions(for: w)
            opts.volume = runtime.volume * Float(masterVolume)
            opts.muted = runtime.muted || globalMuted
            opts.speed = runtime.speed
            opts.fillMode = runtime.fillMode
            apply(ScreenAssignment(wallpaper: w, runtime: runtime),
                  to: displayID, options: opts)
        }
        applyPlaybackPolicy(currentPlaybackPolicy, force: true)
    }

    func stopWallpaper() {
        renderer.stopAll()
        pendingScreenAssignments.removeAll()
        screenAssignments.removeAll()
        stoppedByPlaybackPolicy = false
        currentWallpaper = WallpaperViewModel.invalidWallpaper
    }

    func applyOnScreen(_ w: WEWallpaper, screen: Int) {
        guard let displayID = displayID(for: screen) else { return }
        applyOnDisplay(w, displayID: displayID)
    }

    func applyOnDisplay(_ w: WEWallpaper, displayID targetDisplayID: CGDirectDisplayID) {
        guard w.isValid, w.kind != .unsupported else { return }
        guard renderer.screenIndex(for: targetDisplayID) != nil else { return }
        if targetDisplayID == CGMainDisplayID() {
            currentWallpaper = w
        } else {
            let saved = loadRuntime(for: w)
            var opts = makeRenderOptions(for: w, runtime: saved)
            opts.volume = saved.volume * Float(masterVolume)
            opts.muted = saved.muted || globalMuted
            opts.speed = saved.speed
            opts.fillMode = saved.fillMode
            apply(ScreenAssignment(wallpaper: w, runtime: saved),
                  to: targetDisplayID, options: opts)
            applyPlaybackPolicy(currentPlaybackPolicy, runtime: saved, on: targetDisplayID)
        }
    }

    // MARK: 属性实时下发

    func setProperty(key: String, value: WEPropertyValue) {
        guard var prop = currentWallpaper.project.general?.properties?.items[key] else { return }
        let normalizedValue = prop.normalizedComboValue(value)
        prop.value = normalizedValue
        runtime.propertyOverrides[key] = normalizedValue
        scheduleRuntimeSave()

        switch currentWallpaper.kind {
        case .web, .scene:
            // 场景与网页渲染器都支持实时属性通道：颜色 / 透明度 / 开关(可见性) /
            // 下拉(shader combo & 脚本属性) / 文本 / 字号 均即时生效，无需重启进程。
            pendingPropertyCommands[key] = prop
            propertyCommandWorkItem?.cancel()
            let wallpaperID = currentWallpaper.id
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.currentWallpaper.id == wallpaperID else { return }
                let commands = self.pendingPropertyCommands
                self.pendingPropertyCommands.removeAll(keepingCapacity: true)
                for (key, property) in commands {
                    self.renderer.setProperty(key: key, property: property)
                }
            }
            propertyCommandWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: work)
        case .video, .unsupported:
            break
        }
    }

    func setFillMode(_ mode: FillMode) {
        runtime.fillMode = mode
        renderer.setFillMode(mode)
        scheduleRuntimeSave()
    }

    func resetProperties() {
        runtime = WallpaperRuntimeState()
        saveRuntime()
        suppressPlaybackSideEffects = true
        playVolume = runtime.volume
        playRate = runtime.speed
        suppressPlaybackSideEffects = false
        reapplyCurrent()
    }

    func reapplyVolume() {
        applyPlaybackPolicy(currentPlaybackPolicy)
    }

    /// Re-push the frame rate after the user changes it. `force` because only
    /// the fps component of the applied state changed, and the policy action
    /// itself is unchanged.
    func reapplyFrameRate() {
        applyPlaybackPolicy(currentPlaybackPolicy, force: true)
    }

    func applyPlaybackPolicy(_ action: GSPlayback, force: Bool = false) {
        if action == .stop {
            if !stoppedByPlaybackPolicy {
                renderer.stopAll()
                stoppedByPlaybackPolicy = true
            }
            lastAppliedPlaybackState = nil
            return
        }

        if stoppedByPlaybackPolicy {
            stoppedByPlaybackPolicy = false
            for (displayID, assignment) in screenAssignments.sorted(by: { $0.key < $1.key }) {
                renderer.render(assignment.wallpaper, onDisplay: displayID,
                                options: makeRenderOptions(for: assignment.wallpaper,
                                                           runtime: assignment.runtime))
            }
            lastAppliedPlaybackState = nil
        }

        // The frame rate the app wants right now: the configured rate, reduced
        // when the policy centre reports thermal or low-power pressure.
        let throttledFps = AppDelegate.shared.globalSettingsViewModel.throttledFps(base: globalFps)
        let paused = playRate == 0 || action == .pause
        let powerState: MiragePowerState = paused ? .pause
            : (throttledFps < globalFps ? .throttle : .run)

        let state = AppliedPlaybackState(
            paused: paused,
            muted: runtime.muted || globalMuted || runtime.volume == 0 || action == .mute,
            volume: runtime.volume * masterVolume,
            speed: playRate,
            powerState: powerState,
            fps: throttledFps
        )
        guard force || state != lastAppliedPlaybackState else { return }

        if state.paused {
            renderer.setPower(state.powerState, fps: state.fps)
            renderer.setVolume(state.volume)
            renderer.setMuted(state.muted)
        } else {
            renderer.setVolume(state.volume)
            renderer.setMuted(state.muted)
            renderer.setSpeed(state.speed)
            renderer.setPower(state.powerState, fps: state.fps)
        }
        lastAppliedPlaybackState = state
    }

    private func applyPlaybackPolicy(_ action: GSPlayback, runtime: WallpaperRuntimeState,
                                     on displayID: CGDirectDisplayID) {
        if action == .stop {
            renderer.stop(displayID: displayID)
            return
        }
        let paused = runtime.speed == 0 || action == .pause
        let muted = runtime.muted || globalMuted || runtime.volume == 0 || action == .mute
        let volume = runtime.volume * masterVolume
        let throttledFps = AppDelegate.shared.globalSettingsViewModel.throttledFps(base: globalFps)
        let powerState: MiragePowerState = paused ? .pause
            : (throttledFps < globalFps ? .throttle : .run)

        if paused {
            renderer.setPower(powerState, fps: throttledFps, onDisplay: displayID)
            renderer.setVolume(volume, onDisplay: displayID)
            renderer.setMuted(muted, onDisplay: displayID)
        } else {
            renderer.setVolume(volume, onDisplay: displayID)
            renderer.setMuted(muted, onDisplay: displayID)
            renderer.setSpeed(runtime.speed, onDisplay: displayID)
            renderer.setPower(powerState, fps: throttledFps, onDisplay: displayID)
        }
    }

    // MARK: 状态栏菜单项文字同步（保留原 UI 行为）

    private func syncStatusPauseItem(isPaused: Bool) {
        guard let menu = AppDelegate.shared.statusItem?.menu else { return }
        for item in menu.items {
            if isPaused, item.title == "暂停" {
                item.title = "继续"
                item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
                item.action = #selector(AppDelegate.resume)
                item.target = AppDelegate.shared
            } else if !isPaused, item.title == "继续" {
                item.title = "暂停"
                item.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
                item.action = #selector(AppDelegate.pause)
                item.target = AppDelegate.shared
            }
        }
    }

    private func syncStatusMuteItem(isMuted: Bool) {
        guard let menu = AppDelegate.shared.statusItem?.menu else { return }
        for (i, item) in menu.items.enumerated() {
            if isMuted, item.title == "静音" {
                menu.items[i] = .init(title: "取消静音", systemImage: "speaker.fill",
                                      action: #selector(AppDelegate.unmute), keyEquivalent: "")
            } else if !isMuted, item.title == "取消静音" {
                menu.items[i] = .init(title: "静音", systemImage: "speaker.slash.fill",
                                      action: #selector(AppDelegate.mute), keyEquivalent: "")
            }
        }
    }
}
