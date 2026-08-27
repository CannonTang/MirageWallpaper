//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import Foundation

enum WorkshopMigrationError: LocalizedError {
    case invalidSource
    case cannotRead(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return L("没有找到有效的 431960 创意工坊目录")
        case .cannotRead(let message):
            return L("无法读取迁移目录：%@", message)
        }
    }
}

enum WorkshopMigrationStatus: Equatable {
    case ready
    case destinationExists
    case missingDependency(String)
    case unsupported(String)
    case invalidManifest
    case missingEntry(String)
    case unsafePackage

    var isBlocking: Bool {
        switch self {
        case .unsupported, .invalidManifest, .missingEntry, .unsafePackage:
            return true
        case .ready, .destinationExists, .missingDependency:
            return false
        }
    }

    var title: String {
        switch self {
        case .ready: return L("可迁移")
        case .destinationExists: return L("目标中已存在")
        case .missingDependency(let id): return L("缺少基础壁纸 %@", id)
        case .unsupported(let type): return L("不支持的类型：%@", type)
        case .invalidManifest: return L("project.json 无效")
        case .missingEntry(let path): return L("缺少入口文件：%@", path)
        case .unsafePackage: return L("包含不安全的路径或符号链接")
        }
    }
}

struct WorkshopMigrationItem: Identifiable, Equatable {
    let id: String
    let sourceURL: URL
    let title: String
    let kind: WallpaperKind
    let dependencyID: String?
    let allocatedSize: Int64
    let status: WorkshopMigrationStatus

    var isPreset: Bool { dependencyID != nil }
}

struct WorkshopMigrationScan {
    let sourceRoot: URL
    let items: [WorkshopMigrationItem]

    var selectableIDs: Set<String> {
        Set(items.lazy.filter { !$0.status.isBlocking }.map(\.id))
    }
}

enum WorkshopMigrationConflictPolicy: String, CaseIterable, Identifiable {
    case skip
    case replace

    var id: Self { self }
    var title: String {
        switch self {
        case .skip: return L("保留现有文件并跳过")
        case .replace: return L("备份现有文件后替换")
        }
    }
}

struct WorkshopMigrationResult {
    let importedIDs: [String]
    let skippedIDs: [String]
    let failures: [String: String]
    let backupDirectory: URL?
    let wasCancelled: Bool
}

final class WorkshopMigrationCancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum WorkshopMigrationService {
    private static let fm = FileManager.default

    static func resolveWorkshopRoot(from selectedURL: URL) -> URL? {
        let selected = selectedURL.standardizedFileURL
        var candidates = [selected]
        candidates.append(contentsOf: [
            selected.appending(path: "431960", directoryHint: .isDirectory),
            selected.appending(path: "content/431960", directoryHint: .isDirectory),
            selected.appending(path: "workshop/content/431960", directoryHint: .isDirectory),
            selected.appending(path: "steamapps/workshop/content/431960", directoryHint: .isDirectory)
        ])
        return candidates.first(where: hasWorkshopChildren)
    }

    static func scan(selectedURL: URL) throws -> WorkshopMigrationScan {
        guard let root = resolveWorkshopRoot(from: selectedURL) else {
            throw WorkshopMigrationError.invalidSource
        }
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw WorkshopMigrationError.cannotRead(error.localizedDescription)
        }

        let directories = contents.filter { url in
            let id = url.lastPathComponent
            guard !id.isEmpty, id.allSatisfy(\.isNumber), UInt64(id) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        let sourceIDs = Set(directories.map(\.lastPathComponent))
        let destination = WallpaperLibrary.shared.managedWorkshopDirectory

        let inspected = directories.map { directory -> WorkshopMigrationItem in
            inspect(directory: directory, sourceIDs: sourceIDs, destinationRoot: destination)
        }
        let usableSourceIDs = Set(inspected.lazy.filter { !$0.status.isBlocking }.map(\.id))
        let items = inspected.map { item -> WorkshopMigrationItem in
            guard let dependency = item.dependencyID,
                  sourceIDs.contains(dependency),
                  !usableSourceIDs.contains(dependency),
                  !fm.fileExists(
                    atPath: destination.appending(path: dependency).appending(path: "project.json").path
                  ) else { return item }
            return replacingStatus(of: item, with: .missingDependency(dependency))
        }.sorted {
            let left = UInt64($0.id) ?? 0
            let right = UInt64($1.id) ?? 0
            return left == right ? $0.id < $1.id : left < right
        }
        return WorkshopMigrationScan(sourceRoot: root, items: items)
    }

    static func migrate(
        scan: WorkshopMigrationScan,
        selectedIDs: Set<String>,
        conflictPolicy: WorkshopMigrationConflictPolicy,
        cancellationToken: WorkshopMigrationCancellationToken? = nil,
        progress: ((Int, Int, String) -> Void)? = nil
    ) -> WorkshopMigrationResult {
        let candidates = scan.items.filter {
            selectedIDs.contains($0.id) && !$0.status.isBlocking
        }
        guard !candidates.isEmpty else {
            return WorkshopMigrationResult(
                importedIDs: [], skippedIDs: [], failures: [:], backupDirectory: nil, wasCancelled: false
            )
        }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mirage", directoryHint: .isDirectory)
        let stagingRoot = appSupport
            .appending(path: "Migration Staging", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let backupRoot = appSupport
            .appending(path: "Migration Backups", directoryHint: .isDirectory)
            .appending(path: String(Int(Date().timeIntervalSince1970)), directoryHint: .isDirectory)
        let destinationRoot = WallpaperLibrary.shared.managedWorkshopDirectory

        var imported: [String] = []
        var skipped: [String] = []
        var failures: [String: String] = [:]
        var usedBackup = false
        var wasCancelled = false

        try? fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        for (index, item) in candidates.enumerated() {
            if cancellationToken?.isCancelled == true {
                skipped.append(contentsOf: candidates[index...].map(\.id))
                wasCancelled = true
                break
            }
            progress?(index, candidates.count, item.id)
            let destination = destinationRoot.appending(path: item.id, directoryHint: .isDirectory)
            if item.sourceURL.standardizedFileURL == destination.standardizedFileURL {
                skipped.append(item.id)
                continue
            }
            let destinationExists = fm.fileExists(atPath: destination.path)
            if destinationExists && conflictPolicy == .skip {
                skipped.append(item.id)
                continue
            }

            let staged = stagingRoot.appending(path: item.id, directoryHint: .isDirectory)
            let backup = backupRoot.appending(path: item.id, directoryHint: .isDirectory)
            do {
                try fm.copyItem(at: item.sourceURL, to: staged)
                try normalizeManifest(in: staged)

                var movedExistingToBackup = false
                if destinationExists {
                    try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                    try fm.moveItem(at: destination, to: backup)
                    movedExistingToBackup = true
                    usedBackup = true
                }
                do {
                    try fm.moveItem(at: staged, to: destination)
                } catch {
                    if movedExistingToBackup, !fm.fileExists(atPath: destination.path) {
                        try? fm.moveItem(at: backup, to: destination)
                    }
                    throw error
                }
                WallpaperLibrary.shared.recordAdded(at: destination, workshopID: item.id)
                imported.append(item.id)
            } catch {
                failures[item.id] = error.localizedDescription
                try? fm.removeItem(at: staged)
            }
        }
        progress?(candidates.count, candidates.count, "")
        return WorkshopMigrationResult(
            importedIDs: imported,
            skippedIDs: skipped,
            failures: failures,
            backupDirectory: usedBackup ? backupRoot : nil,
            wasCancelled: wasCancelled
        )
    }

    private static func hasWorkshopChildren(_ root: URL) -> Bool {
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true,
              let contents = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return false }
        return contents.contains { child in
            let id = child.lastPathComponent
            return !id.isEmpty && id.allSatisfy(\.isNumber)
                && fm.fileExists(atPath: child.appending(path: "project.json").path)
        }
    }

    private static func inspect(
        directory: URL,
        sourceIDs: Set<String>,
        destinationRoot: URL
    ) -> WorkshopMigrationItem {
        let id = directory.lastPathComponent
        let destination = destinationRoot.appending(path: id, directoryHint: .isDirectory)
        let size = allocatedSize(of: directory)
        let manifestURL = directory.appending(path: "project.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let project = try? JSONDecoder().decode(WEProject.self, from: data) else {
            return WorkshopMigrationItem(
                id: id, sourceURL: directory, title: id, kind: .unsupported,
                dependencyID: nil, allocatedSize: size, status: .invalidManifest
            )
        }
        let dependency = project.dependency?.rawValue
        let base = WorkshopMigrationItem(
            id: id,
            sourceURL: directory,
            title: project.title.isEmpty ? id : project.title,
            kind: project.normalizedType,
            dependencyID: dependency,
            allocatedSize: size,
            status: .ready
        )

        if packageContainsSymbolicLink(directory) {
            return replacingStatus(of: base, with: .unsafePackage)
        }
        guard project.normalizedType != .unsupported || project.isWorkshopPreset else {
            return replacingStatus(of: base, with: .unsupported(project.type.isEmpty ? L("未知") : project.type))
        }
        if project.isWorkshopPreset, let dependency {
            let installedDependency = fm.fileExists(
                atPath: destinationRoot.appending(path: dependency).appending(path: "project.json").path
            )
            if !sourceIDs.contains(dependency) && !installedDependency {
                return replacingStatus(of: base, with: .missingDependency(dependency))
            }
        } else {
            guard let portable = PathContainment.normalizedManifestPath(project.file),
                  PathContainment.isContained(portable, in: directory) else {
                return replacingStatus(of: base, with: .unsafePackage)
            }
            let entryExists: Bool
            if project.normalizedType == .scene,
               fm.fileExists(atPath: directory.appending(path: "scene.pkg").path) {
                entryExists = true
            } else {
                entryExists = existingRelativePath(portable, in: directory) != nil
            }
            if !entryExists {
                return replacingStatus(of: base, with: .missingEntry(portable))
            }
        }
        if fm.fileExists(atPath: destination.appending(path: "project.json").path) {
            return replacingStatus(of: base, with: .destinationExists)
        }
        return base
    }

    private static func replacingStatus(
        of item: WorkshopMigrationItem,
        with status: WorkshopMigrationStatus
    ) -> WorkshopMigrationItem {
        WorkshopMigrationItem(
            id: item.id,
            sourceURL: item.sourceURL,
            title: item.title,
            kind: item.kind,
            dependencyID: item.dependencyID,
            allocatedSize: item.allocatedSize,
            status: status
        )
    }

    private static func packageContainsSymbolicLink(_ directory: URL) -> Bool {
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return true }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return true
            }
        }
        return false
    }

    private static func existingRelativePath(_ relativePath: String, in root: URL) -> String? {
        guard let normalized = PathContainment.normalizedManifestPath(relativePath), !normalized.isEmpty else {
            return nil
        }
        var current = root
        var resolvedComponents: [String] = []
        for component in normalized.split(separator: "/").map(String.init) {
            guard let children = try? fm.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ), let match = children.first(where: { $0.lastPathComponent == component })
                ?? children.first(where: {
                    $0.lastPathComponent.compare(component, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
                }) else { return nil }
            current = match
            resolvedComponents.append(match.lastPathComponent)
        }
        let resolved = resolvedComponents.joined(separator: "/")
        guard PathContainment.isContained(resolved, in: root), fm.fileExists(atPath: current.path) else {
            return nil
        }
        return resolved
    }

    private static func normalizeManifest(in directory: URL) throws {
        let url = directory.appending(path: "project.json")
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkshopMigrationError.cannotRead(L("project.json 不是对象"))
        }
        for key in ["file", "preview"] {
            guard let raw = object[key] as? String,
                  let normalized = PathContainment.normalizedManifestPath(raw) else { continue }
            object[key] = existingRelativePath(normalized, in: directory) ?? normalized
        }
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: url, options: .atomic)
    }

    private static func allocatedSize(of directory: URL) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
