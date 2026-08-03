//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import SwiftUI

struct WorkshopFilterSidebar: View {
    @ObservedObject var workshopViewModel: WorkshopViewModel

    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 24) {
                    Button {
                        workshopViewModel.clearFilters()
                    } label: {
                        Label("重置筛选", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)

                    FilterSection("类型", alignment: .leading) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(WorkshopTypeFilter.allCases) { filter in
                                Toggle(filter.label, isOn: Binding(
                                    get: { workshopViewModel.typeFilter == filter },
                                    set: { if $0 {
                                        workshopViewModel.typeFilter = filter
                                        workshopViewModel.currentPage = 1
                                        workshopViewModel.search()
                                    }}
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }

                    FilterSection("分级", alignment: .leading) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(WorkshopAgeRating.allCases) { rating in
                                Toggle(rating.displayName, isOn: Binding(
                                    get: { workshopViewModel.ageRatingFilter.contains(rating) },
                                    set: { workshopViewModel.applyAgeRatingFilter(rating, isOn: $0) }
                                ))
                                .toggleStyle(.checkbox)
                            }

                            if workshopViewModel.ageRatingFilter.isEmpty {
                                Text("未选择任何分级，当前显示全部分级")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    FilterSection("标签", alignment: .leading) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button("全选") {
                                    workshopViewModel.selectedTags = Set(WorkshopTag.allCases.map { $0.rawValue })
                                    workshopViewModel.currentPage = 1
                                    workshopViewModel.search()
                                }
                                Button("清空") {
                                    workshopViewModel.selectedTags.removeAll()
                                    workshopViewModel.currentPage = 1
                                    workshopViewModel.search()
                                }
                            }
                            .buttonStyle(.link)

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(WorkshopTag.allCases) { tag in
                                    Toggle(tag.displayName, isOn: Binding(
                                        get: { workshopViewModel.selectedTags.contains(tag.rawValue) },
                                        set: { _ in workshopViewModel.applyTagFilter(tag.rawValue) }
                                    ))
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
            Divider()
        }
    }
}
