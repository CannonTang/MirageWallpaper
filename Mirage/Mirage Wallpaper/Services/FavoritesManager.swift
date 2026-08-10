//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import Foundation

final class FavoritesManager {
    static let shared = FavoritesManager()

    private let key = "FavoriteWallpapers"

    // Guards `ids` so the wallpaper filtering pipeline can read favourites off
    // the main thread while the UI mutates them.
    private let lock = NSLock()
    private var ids: Set<String>

    private init() {
        ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func remapPersistedWallpaperIDs(_ mappings: [String: String]) {
        guard !mappings.isEmpty else { return }
        let key = "FavoriteWallpapers"
        guard let values = UserDefaults.standard.stringArray(forKey: key) else { return }
        let remapper = WallpaperPathRemapper(mappings)
        UserDefaults.standard.set(Array(Set(values.map(remapper.path))), forKey: key)
    }

    private func persist() {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    func isFavorite(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }

    /// Immutable copy for use inside the background filtering pipeline, so it
    /// does not take the lock once per wallpaper.
    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    func toggle(_ id: String) {
        lock.lock()
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        persist()
        lock.unlock()
    }

    func add(_ id: String) {
        lock.lock()
        ids.insert(id)
        persist()
        lock.unlock()
    }

    func remove(_ id: String) {
        lock.lock()
        ids.remove(id)
        persist()
        lock.unlock()
    }
}
