//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import SwiftUI

struct DisplaySettings: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel

    init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    private var screens: [NSScreen] { NSScreen.screens }

    private var currentWallpaper: WEWallpaper {
        AppDelegate.shared.wallpaperViewModel.currentWallpaper
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button {
                    viewModel.isDisplaySettingsReveal = false
                } label: {
                    Image(systemName: "chevron.up").font(.title2).bold()
                }
                .buttonStyle(.link)
                Spacer()
            }

            Text("显示器")
                .font(.largeTitle)

            Text("将当前壁纸「\(currentWallpaper.isValid ? currentWallpaper.project.title : "未选择")」指派到指定显示器。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                        screenRow(index: index, screen: screen)
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            Button("全部停止") {
                AppDelegate.shared.wallpaperViewModel.renderer.stopAll()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func screenRow(index: Int, screen: NSScreen) -> some View {
        let renderer = AppDelegate.shared.wallpaperViewModel.renderer
        let isRunning = renderer.isRendering(on: index)
        let name = screen.localizedName
        let size = screen.frame.size
        return HStack(spacing: 14) {
            Image(systemName: "display")
                .font(.system(size: 32))
                .foregroundStyle(isRunning ? Color.accentColor : .secondary)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text("\(Int(size.width)) × \(Int(size.height))\(index == 0 ? " · 主屏" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                if let w = renderer.currentWallpaper(on: index) {
                    Text("正在渲染：\(w.project.title)")
                        .font(.caption2).foregroundStyle(.tint).lineLimit(1)
                } else {
                    Text("未渲染壁纸").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(spacing: 6) {
                Button("应用到此屏") {
                    applyCurrent(to: index)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!currentWallpaper.isValid)
                if isRunning {
                    Button("停止") { renderer.stop(on: index) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isRunning ? Color.accentColor : .clear, lineWidth: 2))
    }

    private func applyCurrent(to screenIndex: Int) {
        let vm = AppDelegate.shared.wallpaperViewModel
        let w = vm.currentWallpaper
        guard w.isValid, w.kind != .unsupported else { return }
        if w.kind == .web, !vm.isTrusted(w) {
            viewModel.warningUnsafeWallpaperModal(which: w, action: .applyOnScreen(screenIndex))
            return
        }
        vm.applyOnScreen(w, screen: screenIndex)
    }
}
