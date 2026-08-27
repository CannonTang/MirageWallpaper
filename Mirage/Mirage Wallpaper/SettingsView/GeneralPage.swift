//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import SwiftUI

struct GeneralPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            Section {
                Toggle("开机时自动启动 Mirage", isOn: $viewModel.settings.autoStart)
                if viewModel.loginItemStatus == .requiresApproval {
                    HStack {
                        Label(L("需要在系统设置中批准"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(L("打开登录项设置")) {
                            viewModel.openLoginItemSettings()
                        }
                    }
                } else if let loginItemError = viewModel.loginItemError {
                    Label(loginItemError, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                Toggle(L("隐藏菜单栏图标"), isOn: Binding(
                    get: { viewModel.settings.shouldHideMenuBarIcon },
                    set: { viewModel.settings.hideMenuBarIcon = $0 }
                ))
                Picker("菜单栏图标", selection: Binding(
                    get: { viewModel.settings.shouldUseMonochromeMenuBarIcon },
                    set: { viewModel.settings.monochromeMenuBarIcon = $0 }
                )) {
                    Text("彩色").tag(false)
                    Text("黑白").tag(true)
                }
            } header: {
                Label("启动", systemImage: "star.fill")
            }

            Section {
                if UpdateManager.shared.isUpdateServiceAvailable {
                    Toggle("自动检查并下载更新", isOn: Binding(
                        get: { viewModel.settings.shouldAutomaticallyUpdate },
                        set: { viewModel.settings.automaticUpdatesEnabled = $0 }
                    ))
                        .onChange(of: viewModel.settings.shouldAutomaticallyUpdate) { _, _ in
                            UpdateManager.shared.applyAutomaticUpdatePreference()
                        }
                    Toggle("接收测试版更新", isOn: Binding(
                        get: { viewModel.settings.shouldReceivePrereleaseUpdates },
                        set: { viewModel.settings.receivePrereleaseUpdates = $0 }
                    ))
                    .onChange(of: viewModel.settings.shouldReceivePrereleaseUpdates) { _, _ in
                        if viewModel.settings.shouldAutomaticallyUpdate {
                            UpdateManager.shared.checkForUpdates(nil)
                        }
                    }
                    Text("关闭自动更新后，Mirage 不会在后台检查或下载；仍可通过菜单中的“检查更新…”手动检查。开启测试版后，Mirage 会在正式更新之外检查最新的测试版。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("此自定义版本不连接上游更新源，避免本地改造被官方版本覆盖。", systemImage: "shield.checkered")
                    Text("后续版本请从 CannonTang/MirageWallpaper fork 构建或下载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("软件更新", systemImage: "arrow.triangle.2.circlepath")
            }

            Section {
                Picker("语言", selection: $viewModel.settings.language) {
                    Text("跟随系统").tag(GSLocalization.followSystem)
                    Text("English").tag(GSLocalization.en_US)
                    Text("简体中文").tag(GSLocalization.zh_CN)
                    Text("繁體中文").tag(GSLocalization.zh_TW)
                }
            } header: {
                Label("语言", systemImage: "character.bubble")
            }

            Section {
                Picker("外观", selection: $viewModel.settings.appearance) {
                    Text("浅色").tag(GSAppearance.light)
                    Text("深色").tag(GSAppearance.dark)
                    Text("跟随系统").tag(GSAppearance.followSystem)
                }

                Toggle("覆盖壁纸", isOn: Binding(
                    get: { viewModel.settings.shouldOverrideWallpaper },
                    set: { viewModel.settings.overrideWallpaper = $0 }
                ))
                Text("Mirage 会用当前壁纸的画面替换系统桌面图片，让菜单栏与程序坞的取色与壁纸一致。开启后将持续覆盖，退出 Mirage 后依然保留；关闭时仅在 Mirage 运行期间覆盖，退出会自动还原你原本的桌面图片。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("外观", systemImage: "paintpalette.fill")
            }

            Section {
                HStack {
                    Text("全局音量")
                    MirageSlider(value: $viewModel.settings.masterVolume, in: 0...1)
                        .onChange(of: viewModel.settings.masterVolume) { _, _ in
                            AppDelegate.shared.wallpaperViewModel.reapplyVolume()
                        }
                    Text("\(Int(viewModel.settings.masterVolume * 100))%")
                        .monospacedDigit().frame(width: 40)
                }
                Toggle("全局静音", isOn: $viewModel.settings.globalMuted)
                    .onChange(of: viewModel.settings.globalMuted) { _, _ in
                        AppDelegate.shared.wallpaperViewModel.reapplyVolume()
                    }
            } header: {
                Label("音频", systemImage: "speaker.wave.3.fill")
            }

            Section {
                Toggle(L("开发模式"), isOn: Binding(
                    get: { viewModel.settings.isDeveloperModeEnabled },
                    set: { viewModel.settings.developerMode = $0 }
                ))
                HStack {
                    Text("重置所有设置")
                    Spacer()
                    Button {
                        viewModel.settings = GlobalSettings()
                    } label: {
                        Text("重置").frame(width: 100)
                    }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Label("高级", systemImage: "wrench.and.screwdriver.fill")
            }
        }
        .formStyle(.grouped)
    }
}
