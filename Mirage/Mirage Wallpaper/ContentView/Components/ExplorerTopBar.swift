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
        HStack {
            TextField("搜索", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Button {
                viewModel.isFilterReveal.toggle()
            } label: {
                Label("筛选", systemImage: "checklist.checked")
            }
            .buttonStyle(.borderedProminent)
            if globalSettingsViewModel.settings.autoRefresh {
                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            Spacer()
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
            Picker("排序", selection: $viewModel.sortingBy) {
                ForEach(WEWallpaperSortingMethod.allCases) { method in
                    Text(LocalizedStringKey(method.rawValue)).tag(method)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
    }
}
