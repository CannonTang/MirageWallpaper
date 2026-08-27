//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import SwiftUI

struct OnlineServicesPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    @State private var showMirrorWarning = false

    private var apiKeyIsEmpty: Bool {
        viewModel.settings.normalizedSteamAPIKey.isEmpty
    }

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            Section {
                Label("仅“创意工坊”中的在线浏览、搜索和详情需要 Steam Web API。", systemImage: "info.circle.fill")
                Text("已安装壁纸、本地视频、Windows 文件迁移和壁纸播放始终可以离线使用。Steam 登录与壁纸下载也不使用此 API Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("功能范围", systemImage: "network.badge.shield.half.filled")
            }

            if MirageRegion.isMainlandChina {
                Section {
                    Picker("Steam API 线路", selection: $viewModel.settings.steamAPIEndpoint) {
                        Text("Steam 官方 Web API").tag(GSSteamAPIEndpoint.official)
                        Text("SteamCF 镜像").tag(GSSteamAPIEndpoint.mirror)
                    }
                    .onChange(of: viewModel.settings.steamAPIEndpoint) { _, newValue in
                        if newValue == .mirror {
                            showMirrorWarning = true
                        } else {
                            applyEndpointChange()
                        }
                    }
                    Text("线路只影响在线浏览 API，不会加速 Steam 登录、下载或本地导入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("浏览线路", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .alert("SteamCF 镜像警告", isPresented: $showMirrorWarning) {
                    Button("仍要使用") { applyEndpointChange() }
                    Button("取消", role: .cancel) {
                        viewModel.settings.steamAPIEndpoint = .official
                    }
                } message: {
                    Text("该镜像仅允许中国大陆用户访问，且并非 Steam 官方服务，不保证安全性和可用性。它只代理浏览 API，不能加速 Steam 登录或壁纸下载。")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if apiKeyIsEmpty {
                        Label("未设置专属 Key；当前使用内置共享 Key，在线浏览繁忙时可能受限。", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !viewModel.settings.hasValidCustomSteamAPIKey {
                        Label("Key 格式无效，应为 32 位十六进制字符。", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Label("已设置专属 API Key", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    SecureField("Steam Web API Key", text: $viewModel.settings.steamAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("可前往 [Steam API Key 申请页面](https://steamcommunity.com/dev/apikey) 申请，并按页面要求填写域名。Key 只保存在本机，请勿分享。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Steam Web API Key（可选）", systemImage: "key.fill")
            }
        }
        .formStyle(.grouped)
    }

    private func applyEndpointChange() {
        AppDelegate.shared.workshopViewModel.items = []
        AppDelegate.shared.workshopViewModel.currentPage = 1
        AppDelegate.shared.workshopViewModel.search()
    }
}
