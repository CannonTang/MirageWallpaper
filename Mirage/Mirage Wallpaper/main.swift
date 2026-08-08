//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import Cocoa

let mirageOpenWindowNotification = Notification.Name("cn.laobamac.Mirage.openMainWindow")

if let bundleID = Bundle.main.bundleIdentifier,
   NSWorkspace.shared.runningApplications.contains(where: {
       $0.bundleIdentifier == bundleID &&
       $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
   }) {
    DistributedNotificationCenter.default().postNotificationName(
        mirageOpenWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

NSApplication.shared.delegate = AppDelegate.shared
NSApplication.shared.run()
