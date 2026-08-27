//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import Foundation

private let mirageDynamicLockScreenDirectoryName = "MirageDynamicLockScreen"
private let mirageDynamicLockScreenConfigurationName = "dynamic-lock-screen.json"

func mirageDynamicLockScreenConfigurationURL() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent(mirageDynamicLockScreenDirectoryName, isDirectory: true)
        .appendingPathComponent(mirageDynamicLockScreenConfigurationName)
}
