//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import SwiftUI

struct ExplorerTopBar: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    
    @EnvironmentObject var globalSettingsViewModel: GlobalSettingsViewModel
    
    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullBar
            compactBar
        }
    }

    private var fullBar: some View {
        HStack {
            TextField("搜索", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            filterButton(compact: false)
            refreshButton
            WallpaperGridViewMenu(viewModel: viewModel, showsPageSize: true)
            Spacer()
            sortingDirectionButton
            sortingPicker(width: 120)
        }
    }

    private var compactBar: some View {
        HStack(spacing: 8) {
            TextField("搜索", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100, maxWidth: .infinity)
            filterButton(compact: true)
            refreshButton
            WallpaperGridViewMenu(viewModel: viewModel, showsPageSize: true)
            sortingDirectionButton
            sortingPicker(width: 96)
        }
    }

    private func filterButton(compact: Bool) -> some View {
        Button {
            viewModel.isFilterReveal.toggle()
        } label: {
            if compact {
                Image(systemName: "checklist.checked")
                    .frame(width: 16, height: 16)
            } else {
                Label("筛选", systemImage: "checklist.checked")
            }
        }
        .buttonStyle(.borderedProminent)
        .help("筛选")
    }

    private var refreshButton: some View {
        Button {
            viewModel.refresh()
        } label: {
            Group {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .frame(width: 16, height: 16)
        }
        .disabled(viewModel.isRefreshing)
        .help("刷新壁纸库")
    }

    private var sortingDirectionButton: some View {
        Button {
            if viewModel.sortingSequence == .decrease {
                viewModel.sortingSequence = .increase
            } else {
                viewModel.sortingSequence = .decrease
            }
        } label: {
            Image(systemName: viewModel.sortingSequence == .increase ?
                  "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
        }
        .buttonStyle(.plain)
    }

    private func sortingPicker(width: CGFloat) -> some View {
        Picker("排序", selection: $viewModel.sortingBy) {
            ForEach(WEWallpaperSortingMethod.allCases) { method in
                Text(LocalizedStringKey(method.rawValue)).tag(method)
            }
        }
        .labelsHidden()
        .frame(width: width)
    }
}
