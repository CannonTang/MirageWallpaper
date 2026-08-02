//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import SwiftUI

struct WallpaperExplorer: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
    }

    var body: some View {
        let page = viewModel.wallpaperPage
        let selectedDirectory = wallpaperViewModel.currentWallpaper.wallpaperDirectory
        ScrollView {
            if page.items.isEmpty {
                HStack {
                    Spacer()
                    Text("""
                        没有找到匹配的壁纸。
                        请调整或重置左侧筛选条件，或更换搜索关键词。
                        也可以点击底部“导入壁纸”添加新壁纸。
                        """)
                    .font(.title)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .lineSpacing(10)
                    Spacer()
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 50)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: viewModel.explorerIconSize,
                                                       maximum: viewModel.explorerIconSize * 2)
                )], alignment: .leading) {
                    ForEach(page.items) { wallpaper in
                        ExplorerItem(wallpaper: wallpaper,
                                     isSelected: wallpaper.wallpaperDirectory == selectedDirectory)
                            .contextMenu {
                                ExplorerItemMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel, current: wallpaper)
                                ExplorerGlobalMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                            }
                    }
                }
                .padding(.trailing)
            }
        }
        .overlay {
            VStack {
                Spacer()
                if page.pageCount > 1 {
                    let currentPage = min(max(viewModel.currentPage, 1), page.pageCount)
                    HStack(spacing: 6) {
                        Button {
                            viewModel.currentPage = currentPage - 1
                        } label: {
                            Label("上一页", systemImage: "chevron.left")
                        }
                        .disabled(currentPage == 1)
                        .help("上一页")

                        ForEach(Array(pageItems(currentPage: currentPage, pageCount: page.pageCount).enumerated()), id: \.offset) { _, item in
                            if let pageNumber = item {
                                Button {
                                    viewModel.currentPage = pageNumber
                                } label: {
                                    Text("\(pageNumber)")
                                        .font(.callout.weight(pageNumber == currentPage ? .semibold : .regular))
                                        .foregroundStyle(pageNumber == currentPage ? Color.white : Color.primary)
                                        .frame(minWidth: 30, minHeight: 30)
                                        .background(
                                            pageNumber == currentPage ? Color.accentColor : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("第 \(pageNumber) 页")
                            } else {
                                Text("…")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 30)
                            }
                        }

                        Button {
                            viewModel.currentPage = currentPage + 1
                        } label: {
                            Label("下一页", systemImage: "chevron.right")
                        }
                        .disabled(currentPage == page.pageCount)
                        .help("下一页")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14))
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func pageItems(currentPage: Int, pageCount: Int) -> [Int?] {
        guard pageCount > 7 else {
            return Array(1...pageCount).map(Optional.some)
        }

        if currentPage <= 4 {
            return [1, 2, 3, 4, 5, nil, pageCount]
        }

        if currentPage >= pageCount - 3 {
            return [1, nil, pageCount - 4, pageCount - 3, pageCount - 2, pageCount - 1, pageCount]
        }

        return [1, nil, currentPage - 1, currentPage, currentPage + 1, nil, pageCount]
    }
}
