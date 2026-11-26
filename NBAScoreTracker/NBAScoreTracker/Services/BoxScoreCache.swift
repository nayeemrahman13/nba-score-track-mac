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
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var memoryCache: [String: CachedBoxScore] = [:]
    private var trackedDiskEntries: [String: (size: Int, modified: Date)]?
    private var lastPrunedAt: Date?
    
    init(directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        // Versioned directory ignores old entries that may contain live snapshots.
        cacheDirectory = directory ?? cachesDir.appendingPathComponent("NBAScoreTracker/boxscores-v2", isDirectory: true)
        self.now = now
        
        // Create cache directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Public API
    
    /// Returns cached box score if available, nil otherwise
    func get(gameId: String) -> CachedBoxScore? {
        guard NBAFeedLimits.isGameID(gameId) else { return nil }
        // Check memory cache first to avoid disk I/O on hot hits.
        if let cached = memoryCache[gameId], isFresh(cached.cachedAt) {
            return cached
        }
        memoryCache.removeValue(forKey: gameId)

        pruneDisk()

        // Check disk cache
        switch loadFromDisk(gameId: gameId) {
        case .valid(let cached) where cached.gameId == gameId && isFresh(cached.cachedAt):
            remember(cached, for: gameId)
            return cached
        case .valid, .invalid:
            try? FileManager.default.removeItem(at: fileURL(for: gameId))
            trackedDiskEntries?.removeValue(forKey: gameId)
            return nil
        case .missing:
            trackedDiskEntries?.removeValue(forKey: gameId)
            return nil
        }
    }
    
    /// Saves box score to cache (both memory and disk for finished games)
    func save(gameId: String, boxScore: CachedBoxScore, isFinished: Bool) {
        guard isFinished, NBAFeedLimits.isGameID(gameId), boxScore.gameId == gameId,
              isFresh(boxScore.cachedAt),
              let data = try? encoder.encode(boxScore), data.count <= Self.maximumEntryBytes else { return }
        remember(boxScore, for: gameId)
        let url = fileURL(for: gameId)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        let current = now()
        try? FileManager.default.setAttributes([.modificationDate: current], ofItemAtPath: url.path)
        if var entries = trackedDiskEntries {
            entries[gameId] = (size: data.count, modified: current)
            trackedDiskEntries = entries
            let totalBytes = entries.values.reduce(0) { $0 + $1.size }
            let hasExpired = entries.values.contains { !isFresh($0.modified) }
            let stalePrune = lastPrunedAt.map { current.timeIntervalSince($0) >= 300 || current.timeIntervalSince($0) < 0 } ?? true
            if entries.count > Self.maximumEntries || totalBytes > Self.maximumDiskBytes || hasExpired || stalePrune {
                pruneDisk(force: true)
            }
        } else {
            pruneDisk(force: true)
        }
    }
    
    /// Checks if a finished game's box score is already cached
    func hasCached(gameId: String) -> Bool {
        return get(gameId: gameId) != nil
    }
    
    // MARK: - Disk Operations

    private enum DiskLoadResult {
        case missing
        case invalid
        case valid(CachedBoxScore)
    }
    
    private func fileURL(for gameId: String) -> URL {
        cacheDirectory.appendingPathComponent("\(gameId).json")
    }
    
    private func isFresh(_ date: Date) -> Bool {
        let age = now().timeIntervalSince(date)
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
    
    private func loadFromDisk(gameId: String) -> DiskLoadResult {
        let url = fileURL(for: gameId)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)) {
                return .missing
            }
            return FileManager.default.fileExists(atPath: url.path) ? .invalid : .missing
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else { return .invalid }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumEntryBytes + 1),
              data.count <= Self.maximumEntryBytes,
              let decoded = try? decoder.decode(CachedBoxScore.self, from: data) else { return .invalid }
        return .valid(decoded)
    }
    
    private func pruneDisk(force: Bool = false) {
        let current = now()
        if !force, let lastPrunedAt, current.timeIntervalSince(lastPrunedAt) >= 0,
           current.timeIntervalSince(lastPrunedAt) < 300 { return }
        lastPrunedAt = current
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        var entries: [(id: String, url: URL, size: Int, modified: Date)] = []
        for url in files where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  NBAFeedLimits.isGameID(id),
                  let size = values.fileSize, size <= Self.maximumEntryBytes,
                  let modified = values.contentModificationDate, isFresh(modified) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            entries.append((id, url, size, modified))
        }
        entries.sort { $0.modified > $1.modified }
        var totalBytes = 0
        var retained: [String: (size: Int, modified: Date)] = [:]
        for (index, entry) in entries.enumerated() {
            totalBytes += entry.size
            if index >= Self.maximumEntries || totalBytes > Self.maximumDiskBytes {
                try? FileManager.default.removeItem(at: entry.url)
                memoryCache.removeValue(forKey: entry.id)
            } else {
                retained[entry.id] = (size: entry.size, modified: entry.modified)
            }
        }
        trackedDiskEntries = retained
    }
}

// MARK: - Cached Data Model

struct CachedBoxScore: Codable, Equatable, Sendable {
    let gameId: String
    let homeTeam: CachedTeamBoxScore
    let awayTeam: CachedTeamBoxScore
    let homeScore: Int?
    let awayScore: Int?
    let cachedAt: Date
    /// Absent in cache files written before box scores supplied game state.
    let progress: GameProgress?

    init(gameId: String, homeTeam: CachedTeamBoxScore, awayTeam: CachedTeamBoxScore,
         homeScore: Int? = nil, awayScore: Int? = nil, progress: GameProgress? = nil,
         cachedAt: Date = Date()) {
        self.gameId = gameId
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.cachedAt = cachedAt
        self.progress = progress
    }
}

struct CachedTeamBoxScore: Codable, Equatable, Sendable {
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

struct CachedPlayer: Codable, Equatable, Sendable {
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
