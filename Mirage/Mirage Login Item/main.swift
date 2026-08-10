//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AppKit

final class LoginItemDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let identifier = "cn.laobamac.Mirage"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
            NSApp.terminate(nil)
            return
        }

        let mainAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard Bundle(url: mainAppURL)?.bundleIdentifier == identifier else {
            NSApp.terminate(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--launch-at-login"]
        NSWorkspace.shared.openApplication(at: mainAppURL, configuration: configuration) { _, _ in
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = LoginItemDelegate()
app.setActivationPolicy(.prohibited)
app.delegate = delegate
app.run()
