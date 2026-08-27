//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AppKit
import SwiftUI

struct LibraryPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    @State private var librarySources: [WallpaperLibrarySource]

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
        _librarySources = State(initialValue: WallpaperLibrary.shared.librarySources)
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "plus.rectangle.on.folder")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本地优先")
                            .font(.headline)
                        Text("导入视频、壁纸文件夹或 Windows 创意工坊文件都不需要 Steam 账号、API Key 或网络连接。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开导入中心") {
                        AppDelegate.shared.closeSettingsWindow(commit: true)
                        DispatchQueue.main.async {
                            AppDelegate.shared.presentImportCenter()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section {
                ForEach(librarySources) { source in
                    sourceRow(source)
                }
            } header: {
                Label("存储位置", systemImage: "externaldrive.fill")
            }

            Section {
                Toggle("自动刷新壁纸库", isOn: $viewModel.settings.autoRefresh)
                Text("开启后，Mirage 会监视以上目录，并在文件发生变化时自动更新已安装列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("扫描", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func sourceRow(_ source: WallpaperLibrarySource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: source.role))
                    .foregroundStyle(color(for: source.role))
                    .frame(width: 18)
                Text(source.title).font(.callout.bold())
                if source.role == .managedWorkshop {
                    badge("Mirage 下载")
                } else if source.role == .customSteam {
                    badge("直接读取")
                } else if !source.exists {
                    Text("尚未创建")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(source.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(source.url.path(percentEncoded: false))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                if source.role == .steam || source.role == .customSteam {
                    Button("选择 431960 目录…") {
                        chooseDirectory(message: "选择 Wallpaper Engine 创意工坊壁纸所在目录（431960）") { url in
                            WallpaperLibrary.shared.setWorkshopDirectory(url)
                            refresh()
                        }
                    }
                } else if source.role == .imported {
                    Button("选择导入目录…") {
                        chooseDirectory(message: "选择用于存放导入壁纸的目录") { url in
                            WallpaperLibrary.shared.setImportedDirectory(url)
                            refresh()
                        }
                    }
                }
                Button("在访达中显示") {
                    if !source.exists {
                        try? FileManager.default.createDirectory(at: source.url, withIntermediateDirectories: true)
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([source.url])
                    refreshSources()
                }
                if source.role == .customSteam && WallpaperLibrary.shared.isWorkshopDirectoryCustomized {
                    Button("恢复默认") {
                        WallpaperLibrary.shared.setWorkshopDirectory(nil)
                        refresh()
                    }
                } else if source.role == .imported && WallpaperLibrary.shared.isImportedDirectoryCustomized {
                    Button("恢复默认") {
                        WallpaperLibrary.shared.setImportedDirectory(nil)
                        refresh()
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }

    private func icon(for role: WallpaperLibrarySourceRole) -> String {
        switch role {
        case .steam, .customSteam: return "shippingbox.fill"
        case .managedWorkshop, .legacyWorkshop: return "icloud.and.arrow.down.fill"
        case .imported: return "folder.fill"
        }
    }

    private func color(for role: WallpaperLibrarySourceRole) -> Color {
        switch role {
        case .steam, .customSteam: return .blue
        case .managedWorkshop, .legacyWorkshop: return .purple
        case .imported: return .orange
        }
    }

    private func chooseDirectory(message: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("选择")
        panel.message = L(message)
        panel.begin { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
    }

    private func refreshSources() {
        librarySources = WallpaperLibrary.shared.librarySources
    }

    private func refresh() {
        refreshSources()
        AppDelegate.shared.contentViewModel.refresh()
    }
}
