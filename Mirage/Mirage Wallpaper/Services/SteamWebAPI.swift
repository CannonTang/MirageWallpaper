//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

import Foundation

final class SteamWebAPI {
    static let shared = SteamWebAPI()

    private let builtInKey: String = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "MirageSteamWebAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil ? value : ""
    }()
    private var apiKey: String {
        let settings = AppDelegate.shared.globalSettingsViewModel.settings
        return settings.hasValidCustomSteamAPIKey ? settings.normalizedSteamAPIKey : builtInKey
    }
    private let appId = "431960"
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
    private let decoder = JSONDecoder()
    private let imageCache = NSCache<NSString, CacheEntry>()
    private let creatorCache = NSCache<NSString, CreatorCacheEntry>()
    private let requestThrottle = SteamRequestThrottle(interval: 0.35)

    private static let officialBase = "https://api.steampowered.com/"
    private static let mirrorBase = "https://steams.524228.xyz/"

    private var baseURL: String {
        switch AppDelegate.shared.globalSettingsViewModel.settings.steamAPIEndpoint {
        case .official: return Self.officialBase
        case .mirror: return Self.mirrorBase
        }
    }

    private let cacheDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Mirage/WorkshopCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    final class CacheEntry {
        let data: Data
        let date: Date
        init(data: Data) {
            self.data = data
            self.date = Date()
        }
    }

    final class CreatorCacheEntry {
        let creator: WorkshopCreator
        let date: Date

        init(creator: WorkshopCreator) {
            self.creator = creator
            self.date = Date()
        }
    }

    // MARK: - Query Workshop Files

    func queryFiles(
        searchText: String = "",
        tags: [String] = [],
        sortOrder: WorkshopSortOrder = .trending,
        typeFilter: WorkshopTypeFilter = .all,
        ageRating: WorkshopAgeRatingFilter = .all,
        page: Int = 1,
        perPage: Int = 30
    ) async throws -> (items: [WorkshopItem], total: Int) {
        await throttle()

        var params: [String: String] = [
            "key": apiKey,
            "query_type": "\(sortOrder.apiValue)",
            "page": "\(page)",
            "numperpage": "\(perPage)",
            "appid": appId,
            "filetype": "0",
            "return_tags": "true",
            "return_previews": "true",
            "return_metadata": "true",
            "strip_description_bbcode": "true",
        ]

        if sortOrder == .trending {
            params["days"] = "7"
            params["include_recent_votes_only"] = "true"
        }

        if !searchText.isEmpty {
            params["search_text"] = searchText
        }

        let selectableTags = Set(WorkshopTag.allCases.map(\.rawValue))
        let requestedTags = Set(tags)
        var allTags = selectableTags.isSubset(of: requestedTags)
            ? tags.filter { !selectableTags.contains($0) }
            : tags
        if typeFilter != .all {
            allTags.append(typeFilter.rawValue.capitalized)
        }
        for (index, tag) in allTags.enumerated() {
            params["requiredtags[\(index)]"] = tag
        }

        // Ratings are mutually exclusive, so AND-ing them as `requiredtags`
        // would match nothing; the unchecked ones are excluded instead.
        // `excludedtags` is orthogonal, so type/genre keep their AND semantics.
        let excluded = ageRating.excludedRatings
        for (index, rating) in excluded.enumerated() {
            params["excludedtags[\(index)]"] = rating.steamTag
        }

        var components = URLComponents(string: baseURL + "IPublishedFileService/QueryFiles/v1/")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw SteamAPIError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SteamAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw SteamAPIError.httpError(httpResponse.statusCode)
        }

        let apiResponse = try decoder.decode(SteamAPIResponse.self, from: data)
        let decodedItems = apiResponse.response.publishedfiledetails?.map { $0.toWorkshopItem() } ?? []
        let visibleItems = decodedItems.filter { $0.fileSize > 0 }
        let items = await enrichCreators(in: visibleItems)
        let total = apiResponse.response.total ?? items.count

        return (items, total)
    }

    // MARK: - Get File Details

    func getFileDetails(workshopIds: [String]) async throws -> [WorkshopItem] {
        await throttle()

        let components = URLComponents(string: baseURL + "ISteamRemoteStorage/GetPublishedFileDetails/v1/")!

        var bodyParams = "itemcount=\(workshopIds.count)"
        for (index, id) in workshopIds.enumerated() {
            bodyParams += "&publishedfileids[\(index)]=\(id)"
        }

        guard let url = components.url else {
            throw SteamAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyParams.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SteamAPIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw SteamAPIError.httpError(httpResponse.statusCode)
        }

        let apiResponse = try decoder.decode(SteamAPIResponse.self, from: data)
        let items = (apiResponse.response.publishedfiledetails ?? [])
            .map { $0.toWorkshopItem() }
            .filter { $0.fileSize > 0 }
        return await enrichCreators(in: items)
    }

    func creatorProfile(steamId: String) async -> WorkshopCreator? {
        let normalized = steamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let cached = cachedCreator(steamId: normalized) {
            return cached
        }
        let profiles = try? await fetchCreatorProfiles(steamIds: [normalized])
        return profiles?[normalized]
    }

    // MARK: - Trending / Featured

    func fetchTrending(count: Int = 10, ageRating: WorkshopAgeRatingFilter = .all) async throws -> [WorkshopItem] {
        let result = try await queryFiles(sortOrder: .trending, ageRating: ageRating, page: 1, perPage: count)
        return result.items
    }

    func fetchMostRecent(count: Int = 10, ageRating: WorkshopAgeRatingFilter = .all) async throws -> [WorkshopItem] {
        let result = try await queryFiles(sortOrder: .mostRecent, ageRating: ageRating, page: 1, perPage: count)
        return result.items
    }

    func fetchMostSubscribed(count: Int = 10, ageRating: WorkshopAgeRatingFilter = .all) async throws -> [WorkshopItem] {
        let result = try await queryFiles(sortOrder: .mostSubscribed, ageRating: ageRating, page: 1, perPage: count)
        return result.items
    }

    func fetchTopRated(count: Int = 10, ageRating: WorkshopAgeRatingFilter = .all) async throws -> [WorkshopItem] {
        let result = try await queryFiles(sortOrder: .topRated, ageRating: ageRating, page: 1, perPage: count)
        return result.items
    }

    func fetchByTag(
        _ tag: String,
        sortOrder: WorkshopSortOrder = .trending,
        count: Int = 10,
        ageRating: WorkshopAgeRatingFilter = .all
    ) async throws -> [WorkshopItem] {
        let result = try await queryFiles(
            tags: [tag], sortOrder: sortOrder, ageRating: ageRating, page: 1, perPage: count)
        return result.items
    }

    // MARK: - Image Download

    func downloadPreviewImage(url: URL) async throws -> Data {
        let cacheKey = NSString(string: url.absoluteString)

        if let cached = imageCache.object(forKey: cacheKey),
           Date().timeIntervalSince(cached.date) < 300 {
            return cached.data
        }

        let diskPath = cacheDirectory.appending(path: url.absoluteString.hash.description + ".gif")
        if let diskData = try? Data(contentsOf: diskPath) {
            let entry = CacheEntry(data: diskData)
            imageCache.setObject(entry, forKey: cacheKey)
            return diskData
        }

        let (data, _) = try await session.data(from: url)

        let entry = CacheEntry(data: data)
        imageCache.setObject(entry, forKey: cacheKey)

        try? data.write(to: diskPath, options: .atomic)

        return data
    }

    // MARK: - Check Downloaded

    func isItemDownloaded(_ workshopId: String) -> Bool {
        downloadedItemURL(workshopId) != nil
    }

    func downloadedItemURL(_ workshopId: String) -> URL? {
        let dirs = [
            WallpaperLibrary.shared.steamWorkshopDirectory,
            WallpaperLibrary.shared.defaultSteamWorkshopDirectory
        ] + SteamCMDManager.shared.steamCMDContentDirectories
        return dirs
            .map { $0.appending(path: workshopId) }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "project.json").path) }
    }

    // MARK: - Throttle

    private func throttle() async {
        await requestThrottle.wait()
    }

    private func enrichCreators(in items: [WorkshopItem]) async -> [WorkshopItem] {
        let steamIds = Set(items.map(\.creatorSteamId).filter { !$0.isEmpty })
        guard !steamIds.isEmpty else { return items }

        var creators: [String: WorkshopCreator] = [:]
        var missingIds: [String] = []
        for steamId in steamIds {
            if let creator = cachedCreator(steamId: steamId) {
                creators[steamId] = creator
            } else {
                missingIds.append(steamId)
            }
        }

        if !missingIds.isEmpty,
           let fetched = try? await fetchCreatorProfiles(steamIds: missingIds) {
            creators.merge(fetched) { _, new in new }
        }

        return items.map { item in
            guard let creator = creators[item.creatorSteamId] else { return item }
            var enriched = item
            enriched.creatorName = creator.name
            enriched.creatorAvatarURL = creator.avatarURL
            enriched.creatorProfileURL = creator.profileURL
            return enriched
        }
    }

    private func cachedCreator(steamId: String) -> WorkshopCreator? {
        let key = NSString(string: steamId)
        guard let entry = creatorCache.object(forKey: key) else { return nil }
        if Date().timeIntervalSince(entry.date) > 3_600 {
            creatorCache.removeObject(forKey: key)
            return nil
        }
        return entry.creator
    }

    private func fetchCreatorProfiles(steamIds: [String]) async throws -> [String: WorkshopCreator] {
        guard !apiKey.isEmpty else { return [:] }
        var result: [String: WorkshopCreator] = [:]

        for start in stride(from: 0, to: steamIds.count, by: 100) {
            let end = min(start + 100, steamIds.count)
            let batch = Array(steamIds[start..<end])
            await throttle()

            var components = URLComponents(string: baseURL + "ISteamUser/GetPlayerSummaries/v2/")!
            components.queryItems = [
                URLQueryItem(name: "key", value: apiKey),
                URLQueryItem(name: "steamids", value: batch.joined(separator: ","))
            ]
            guard let url = components.url else { throw SteamAPIError.invalidURL }

            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SteamAPIError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw SteamAPIError.httpError(httpResponse.statusCode)
            }

            let apiResponse = try decoder.decode(SteamPlayerSummariesResponse.self, from: data)
            for player in apiResponse.response.players {
                let creator = WorkshopCreator(
                    steamId: player.steamid,
                    name: player.personaname,
                    avatarURL: player.avatarmedium.flatMap(URL.init(string:)),
                    profileURL: player.profileurl.flatMap(URL.init(string:))
                )
                result[player.steamid] = creator
                creatorCache.setObject(CreatorCacheEntry(creator: creator), forKey: NSString(string: player.steamid))
            }
        }

        return result
    }
}

private actor SteamRequestThrottle {
    private let interval: TimeInterval
    private var nextAllowed = Date.distantPast

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func wait() async {
        let now = Date()
        let scheduled = max(now, nextAllowed)
        nextAllowed = scheduled.addingTimeInterval(interval)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

// MARK: - Errors

enum SteamAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return L("无效的 API 地址")
        case .invalidResponse: return L("无效的服务器响应")
        case .httpError(401), .httpError(403): return L("Steam API Key 无效、权限不足或当前线路拒绝访问")
        case .httpError(429): return L("Steam Web API 请求过于频繁，请稍后重试或设置专属 API Key")
        case .httpError(let code): return L("HTTP 错误: %@", String(code))
        case .decodingError(let msg): return L("数据解析错误: %@", msg)
        }
    }
}
