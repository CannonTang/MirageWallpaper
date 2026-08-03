//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import SwiftUI

struct WorkshopSearchBar: View {
    @ObservedObject var workshopViewModel: WorkshopViewModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索作品、作者或作品 ID...", text: $workshopViewModel.searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        workshopViewModel.submitSearch()
                    }
                if !workshopViewModel.searchText.isEmpty {
                    Button {
                        workshopViewModel.searchText = ""
                        workshopViewModel.currentPage = 1
                        workshopViewModel.search()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(nsColor: NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            if workshopViewModel.showsCreatorSearch {
                Menu {
                    ForEach(workshopViewModel.matchingCreators) { creator in
                        Button {
                            workshopViewModel.openCreatorWorkshop(creator)
                        } label: {
                            Label(creator.name, systemImage: "person.crop.circle")
                        }
                    }
                    if !workshopViewModel.matchingCreators.isEmpty {
                        Divider()
                    }
                    Button {
                        workshopViewModel.searchCreatorOnSteam()
                    } label: {
                        Label("在 Steam 中搜索作者", systemImage: "magnifyingglass")
                    }
                } label: {
                    Label("作者", systemImage: "person.2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("查看匹配作者的 Wallpaper Engine 作品")
            }

            Picker("排序", selection: Binding(
                get: { workshopViewModel.sortOrder },
                set: { newValue in
                    workshopViewModel.sortOrder = newValue
                    workshopViewModel.currentPage = 1
                    workshopViewModel.search()
                }
            )) {
                ForEach(WorkshopSortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
        }
    }
}
