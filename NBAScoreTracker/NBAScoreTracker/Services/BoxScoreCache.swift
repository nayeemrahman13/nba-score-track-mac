import Foundation

/// Caches box score data for finished games to avoid repeated API calls.
/// Only verified final box scores are cached, with a TTL for official corrections.
actor BoxScoreCache {
    static let shared = BoxScoreCache()
    static let lifetime: TimeInterval = 21_600
    static let maximumEntryBytes = 256 * 1024
    static let maximumDiskBytes = 16 * 1024 * 1024
    static let maximumEntries = 100
    
    private let cacheDirectory: URL
    private var memoryCache: [String: CachedBoxScore] = [:]
    private var lastPrunedAt: Date?
    
    init(directory: URL? = nil) {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        // Versioned directory ignores old entries that may contain live snapshots.
        cacheDirectory = directory ?? cachesDir.appendingPathComponent("NBAScoreTracker/boxscores-v2", isDirectory: true)
        
        // Create cache directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Public API
    
    /// Returns cached box score if available, nil otherwise
    func get(gameId: String) -> CachedBoxScore? {
        guard NBAFeedLimits.isGameID(gameId) else { return nil }
        pruneDisk()
        // Check memory cache first
        if let cached = memoryCache[gameId], isFresh(cached.cachedAt) {
            return cached
        }
        memoryCache.removeValue(forKey: gameId)
        
        // Check disk cache
        if let cached = loadFromDisk(gameId: gameId), cached.gameId == gameId, isFresh(cached.cachedAt) {
            remember(cached, for: gameId)
            return cached
        }
        try? FileManager.default.removeItem(at: fileURL(for: gameId))
        
        return nil
    }
    
    /// Saves box score to cache (both memory and disk for finished games)
    func save(gameId: String, boxScore: CachedBoxScore, isFinished: Bool) {
        guard isFinished, NBAFeedLimits.isGameID(gameId), boxScore.gameId == gameId,
              isFresh(boxScore.cachedAt),
              let data = try? JSONEncoder().encode(boxScore), data.count <= Self.maximumEntryBytes else { return }
        remember(boxScore, for: gameId)
        try? data.write(to: fileURL(for: gameId), options: .atomic)
        pruneDisk(force: true)
    }
    
    /// Checks if a finished game's box score is already cached
    func hasCached(gameId: String) -> Bool {
        return get(gameId: gameId) != nil
    }
    
    // MARK: - Disk Operations
    
    private func fileURL(for gameId: String) -> URL {
        cacheDirectory.appendingPathComponent("\(gameId).json")
    }
    
    private func isFresh(_ date: Date) -> Bool {
        let age = Date().timeIntervalSince(date)
        return age >= 0 && age < Self.lifetime
    }

    private func remember(_ box: CachedBoxScore, for gameId: String) {
        memoryCache = memoryCache.filter { isFresh($0.value.cachedAt) }
        if memoryCache[gameId] == nil, memoryCache.count >= Self.maximumEntries,
           let oldest = memoryCache.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
            memoryCache.removeValue(forKey: oldest)
        }
        memoryCache[gameId] = box
    }
    
    private func loadFromDisk(gameId: String) -> CachedBoxScore? {
        let url = fileURL(for: gameId)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumEntryBytes + 1),
              data.count <= Self.maximumEntryBytes else { return nil }
        return try? JSONDecoder().decode(CachedBoxScore.self, from: data)
    }
    
    private func pruneDisk(force: Bool = false) {
        let now = Date()
        if !force, let lastPrunedAt, now.timeIntervalSince(lastPrunedAt) >= 0,
           now.timeIntervalSince(lastPrunedAt) < 300 { return }
        lastPrunedAt = now
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        var entries: [(url: URL, size: Int, modified: Date)] = []
        for url in files where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  NBAFeedLimits.isGameID(url.deletingPathExtension().lastPathComponent),
                  let size = values.fileSize, size <= Self.maximumEntryBytes,
                  let modified = values.contentModificationDate, isFresh(modified) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            entries.append((url, size, modified))
        }
        entries.sort { $0.modified > $1.modified }
        var totalBytes = 0
        for (index, entry) in entries.enumerated() {
            totalBytes += entry.size
            if index >= Self.maximumEntries || totalBytes > Self.maximumDiskBytes {
                try? FileManager.default.removeItem(at: entry.url)
                memoryCache.removeValue(forKey: entry.url.deletingPathExtension().lastPathComponent)
            }
        }
    }
}

// MARK: - Cached Data Model

struct CachedBoxScore: Codable {
    let gameId: String
    let homeTeam: CachedTeamBoxScore
    let awayTeam: CachedTeamBoxScore
    let homeScore: Int?
    let awayScore: Int?
    let cachedAt: Date
    
    init(gameId: String, homeTeam: CachedTeamBoxScore, awayTeam: CachedTeamBoxScore, homeScore: Int? = nil, awayScore: Int? = nil) {
        self.gameId = gameId
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.cachedAt = Date()
    }
}

struct CachedTeamBoxScore: Codable {
    let tricode: String
    let players: [CachedPlayer]

    var leaders: [Player] {
        players.prefix(3).enumerated().map { index, player in
            // Old cache files have no ID. Use a unique team-scoped slot until
            // their next refresh replaces them with NBA player identities.
            player.toPlayer(fallbackID: "legacy:\(tricode):\(index)")
        }
    }
}

struct CachedPlayer: Codable {
    var id: String?
    let name: String
    let nameI: String
    let position: String
    let points: Int
    let rebounds: Int
    let assists: Int
    let steals: Int
    let blocks: Int
    let minutes: String
    let fgm: Int
    let fga: Int
    let threePm: Int
    let threePa: Int
    let ftm: Int
    let fta: Int
    
    func toPlayer(fallbackID: String = UUID().uuidString) -> Player {
        Player(
            id: id ?? fallbackID,
            name: name,
            nameI: nameI,
            position: position,
            points: points,
            rebounds: rebounds,
            assists: assists,
            steals: steals,
            blocks: blocks,
            minutes: minutes,
            fgm: fgm,
            fga: fga,
            threePm: threePm,
            threePa: threePa,
            ftm: ftm,
            fta: fta
        )
    }
}
