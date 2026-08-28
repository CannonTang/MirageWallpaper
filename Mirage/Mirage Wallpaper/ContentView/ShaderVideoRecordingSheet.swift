//
//  Mirage Wallpaper
//
//  User-configurable offline Shader recording and playback routing.
//

import SwiftUI

enum ShaderVideoRecordingPurpose {
    case recordOnly
    case wallpaper(DisplayKey)
    case allDisplays
    case screenSaver
    case dynamicLockScreen

    var title: String {
        switch self {
        case .recordOnly: return L("录制 Shader 视频")
        case .wallpaper, .allDisplays: return L("使用录制视频作为壁纸")
        case .screenSaver: return L("录制并设为屏保")
        case .dynamicLockScreen: return L("录制并设为动态锁屏")
        }
    }
}

struct ShaderVideoRecordingRequest: Identifiable {
    let id = UUID()
    let wallpaper: WEWallpaper
    let purpose: ShaderVideoRecordingPurpose
}

struct ShaderVideoRecordingSheet: View {
    let request: ShaderVideoRecordingRequest
    @ObservedObject var contentViewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var settings = ShadertoyVideoRecordingSettings.load()
    @State private var forceRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "film.stack")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.purpose.title)
                        .font(.title2.bold())
                    Text(request.wallpaper.project.title)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Form {
                Picker("分辨率", selection: $settings.longestEdge) {
                    Text("当前主屏原生").tag(0)
                    Text("720p").tag(1280)
                    Text("1080p").tag(1920)
                    Text("1440p").tag(2560)
                    Text("4K").tag(4096)
                }
                Picker("帧率", selection: $settings.fps) {
                    Text("24 FPS").tag(24)
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }
                Picker("时长", selection: $settings.duration) {
                    Text("10 秒").tag(10)
                    Text("20 秒").tag(20)
                    Text("30 秒").tag(30)
                    Text("60 秒").tag(60)
                }
                Picker("编码画质", selection: $settings.quality) {
                    ForEach(ShadertoyVideoQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Picker("循环衔接", selection: $settings.transitionMode) {
                    ForEach(ShadertoyLoopTransitionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if settings.transitionMode == .colorFade {
                    ColorPicker(
                        "衔接颜色",
                        selection: transitionColorBinding,
                        supportsOpacity: false
                    )
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 8) {
                if hasExistingCache {
                    Label(existingCacheMessage,
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Toggle("忽略缓存并强制重新录制", isOn: $forceRecording)
                } else {
                    Label("尚无录制缓存，开始后会在后台逐帧生成视频。",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                Text(transitionExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("录制视频始终使用固定向前时间轴，不会生成或播放倒放画面。分辨率、帧率、时长和画质越高，录制耗时与文件体积越大。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button(primaryButtonTitle) { start() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    @MainActor
    private var hasExistingCache: Bool {
        ShadertoyLoopVideoExporter.shared.hasCachedVideo(for: request.wallpaper)
    }

    private var primaryButtonTitle: String {
        if hasExistingCache && !forceRecording { return L("使用缓存或开始录制") }
        return L("开始录制")
    }

    private var transitionColorBinding: Binding<Color> {
        Binding(
            get: {
                let color = settings.transitionColor.sanitized
                return Color(
                    .sRGB,
                    red: color.red,
                    green: color.green,
                    blue: color.blue,
                    opacity: 1
                )
            },
            set: { color in
                let converted = NSColor(color).usingColorSpace(.sRGB) ?? .black
                settings.transitionColor = ShadertoyVideoTransitionColor(
                    red: Double(converted.redComponent),
                    green: Double(converted.greenComponent),
                    blue: Double(converted.blueComponent)
                ).sanitized
            }
        )
    }

    private var transitionExplanation: String {
        switch settings.transitionMode {
        case .direct:
            return L("直接衔接不会在录制端插入黑帧或混合帧；适合 Shader 自身首尾时间完全闭合的情况。")
        case .crossfade:
            return L("交叉淡化会在结尾最多 1 秒逐渐混合到首帧，不会叠加纯色。")
        case .colorFade:
            return L("颜色淡化会在开头从所选颜色淡入，并在结尾淡回同一颜色，使循环点两侧保持连续。")
        }
    }

    @MainActor
    private var existingCacheMessage: String {
        if let info = ShadertoyLoopVideoExporter.shared.cachedVideoInfo(
            for: request.wallpaper
        ) {
            return L("已有缓存：%@。内容与配置匹配时会直接复用。", info.summary)
        }
        return L("检测到旧版录制缓存；开始后会验证并尽可能直接复用。")
    }

    private func start() {
        let selectedSettings = settings.sanitized
        selectedSettings.save()
        let sourceWallpaper = request.wallpaper
        let purpose = request.purpose
        let force = forceRecording
        dismiss()

        Task { @MainActor in
            do {
                let prepared = try await ShadertoyLoopVideoExporter.shared.prepareVideo(
                    for: sourceWallpaper,
                    recordingSettings: selectedSettings,
                    forceRecording: force
                )
                try apply(
                    prepared,
                    sourceWallpaper: sourceWallpaper,
                    purpose: purpose
                )
                contentViewModel.screenSaverFeedback = ScreenSaverFeedback(
                    title: successTitle(for: purpose),
                    message: successMessage(
                        for: purpose,
                        sourceWallpaper: sourceWallpaper,
                        usedCache: prepared.usedCache
                    )
                )
            } catch {
                contentViewModel.screenSaverFeedback = ScreenSaverFeedback(
                    title: L("Shader 视频处理失败"),
                    message: error.localizedDescription
                )
            }
        }
    }

    @MainActor
    private func apply(_ prepared: ShadertoyLoopVideoExporter.PreparedVideo,
                       sourceWallpaper: WEWallpaper,
                       purpose: ShaderVideoRecordingPurpose) throws {
        let runtime = wallpaperViewModel.loadRuntime(for: sourceWallpaper)
        let properties = wallpaperViewModel.effectiveProperties(
            for: sourceWallpaper,
            runtime: runtime
        )
        let fps = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)

        switch purpose {
        case .recordOnly:
            break
        case .wallpaper(let key):
            wallpaperViewModel.requestApply(prepared.wallpaper, to: key)
        case .allDisplays:
            wallpaperViewModel.applyToAllDisplays(prepared.wallpaper)
        case .screenSaver:
            if !ScreenSaverManager.shared.isInstalled {
                try ScreenSaverManager.shared.install()
            }
            try ScreenSaverManager.shared.configure(
                with: prepared.wallpaper,
                runtime: runtime,
                properties: properties,
                fps: fps
            )
        case .dynamicLockScreen:
            try ScreenSaverDynamicLockScreenManager.shared.configureCurrentWallpaper(
                prepared.wallpaper,
                runtime: runtime,
                properties: properties,
                fps: fps
            )
        }
    }

    private func successTitle(for purpose: ShaderVideoRecordingPurpose) -> String {
        switch purpose {
        case .recordOnly: return L("Shader 视频已就绪")
        case .wallpaper, .allDisplays: return L("已使用录制视频作为壁纸")
        case .screenSaver: return L("已设为屏保")
        case .dynamicLockScreen: return L("已设为动态锁屏")
        }
    }

    private func successMessage(for purpose: ShaderVideoRecordingPurpose,
                                sourceWallpaper: WEWallpaper,
                                usedCache: Bool) -> String {
        let action: String
        switch purpose {
        case .recordOnly:
            action = L("“%@”的录制视频已保存。", sourceWallpaper.project.title)
        case .wallpaper, .allDisplays:
            action = L("“%@”正在以低负载视频模式播放。", sourceWallpaper.project.title)
        case .screenSaver:
            action = L("“%@”将在下次启动屏保时显示。", sourceWallpaper.project.title)
        case .dynamicLockScreen:
            action = L("锁屏时将播放“%@”，解锁后会恢复原桌面墙纸。", sourceWallpaper.project.title)
        }
        let cache = usedCache
            ? L("\n已复用匹配的录制缓存。")
            : L("\n已按所选配置生成并缓存新视频。")
        return action + cache
    }
}
