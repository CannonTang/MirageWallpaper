//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import AppKit
import Foundation

struct WallpaperPathRemapper {
    private let mappings: [(old: String, new: String)]

    init(_ paths: [String: String]) {
        mappings = paths.map {
            ($0.key.standardizedPath, $0.value.standardizedPath)
        }.sorted { $0.old.count > $1.old.count }
    }

    func path(_ value: String) -> String {
        let standardized = value.standardizedPath
        for mapping in mappings {
            if standardized == mapping.old { return mapping.new }
            if standardized.hasPrefix(mapping.old + "/") {
                return mapping.new + standardized.dropFirst(mapping.old.count)
            }
        }
        return value
    }

    func url(_ value: URL) -> URL {
        guard value.isFileURL else { return value }
        let remapped = path(value.path)
        return remapped == value.path ? value : URL(fileURLWithPath: remapped)
    }
}

private extension String {
    var standardizedPath: String {
        URL(fileURLWithPath: self).standardizedFileURL.path
    }
}

enum LegacyWorkshopMigration {
    private struct Candidate {
        let source: URL
        let destination: URL
    }

    static func runIfNeeded() {
        let library = WallpaperLibrary.shared
        let candidates = migrationCandidates(
            from: library.legacyWorkshopDirectories,
            to: library.managedWorkshopDirectory
        )
        guard !candidates.isEmpty else { return }

        let prompt = NSAlert()
        prompt.alertStyle = .informational
        prompt.messageText = L("发现旧版 Mirage 下载的壁纸")
        prompt.informativeText = L("检测到 %d 张壁纸仍在旧下载目录。是否将它们移动到新的 Mirage 下载目录？不会复制壁纸，也不会覆盖已有项目。", candidates.count)
        prompt.addButton(withTitle: L("迁移"))
        prompt.addButton(withTitle: L("稍后"))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard prompt.runModal() == .alertFirstButtonReturn else { return }

        let result = migrate(candidates)
        if !result.mappings.isEmpty {
            WallpaperViewModel.remapPersistedPaths(result.mappings)
            PlaylistManager.remapPersistedWallpaperIDs(result.mappings)
            FavoritesManager.remapPersistedWallpaperIDs(result.mappings)
            WallpaperShortcutManager.remapPersistedWallpaperIDs(result.mappings)
            ScreenSaverManager.shared.remapPersistedPaths(result.mappings)
        }

        guard !result.unresolved.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("部分壁纸未迁移")
        alert.informativeText = L("已移动 %d 张壁纸，另有 %d 张因目标中已有同名项目或文件系统错误而保留在旧目录。Mirage 仍会显示这些旧目录中的壁纸。", result.mappings.count, result.unresolved.count)
        alert.addButton(withTitle: L("好"))
        alert.runModal()
    }

    private static func migrationCandidates(from roots: [URL], to destinationRoot: URL) -> [Candidate] {
        let fm = FileManager.default
        var result: [Candidate] = []
        for root in roots {
            guard let contents = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for source in contents {
                let id = source.lastPathComponent
                guard !id.isEmpty, id.allSatisfy(\.isNumber), UInt64(id) != nil,
                      let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      fm.fileExists(atPath: source.appending(path: "project.json").path) else { continue }
                result.append(Candidate(
                    source: source.standardizedFileURL,
                    destination: destinationRoot.appending(path: id, directoryHint: .isDirectory).standardizedFileURL
                ))
            }
        }
        return result.sorted { $0.source.path < $1.source.path }
    }

    private static func migrate(_ candidates: [Candidate]) -> (mappings: [String: String], unresolved: [String]) {
        let fm = FileManager.default
        var mappings: [String: String] = [:]
        var unresolved: [String] = []
        do {
            if let destinationRoot = candidates.first?.destination.deletingLastPathComponent() {
                try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            }
        } catch {
            return ([:], candidates.map(\.source.path))
        }
        for candidate in candidates {
            guard !fm.fileExists(atPath: candidate.destination.path) else {
                unresolved.append(candidate.source.path)
                continue
            }
            do {
                try fm.moveItem(at: candidate.source, to: candidate.destination)
                mappings[candidate.source.path] = candidate.destination.path
            } catch {
                unresolved.append(candidate.source.path)
            }
        }
        return (mappings, unresolved)
    }
}
