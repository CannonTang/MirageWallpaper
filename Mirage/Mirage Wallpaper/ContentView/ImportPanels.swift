//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import Cocoa

extension AppDelegate {
    @objc func openImportFromFolderPanel() {
        presentImportCenter()
    }

    @objc func openImportFromFoldersPanel() {
        presentImportCenter()
    }

    func presentImportCenter() {
        openMainWindow()
        contentViewModel.isImportCenterPresented = true
    }
}
