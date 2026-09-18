import Foundation

/// Caches box score data for finished games to avoid repeated API calls.
/// Only verified final box scores are cached, with a TTL for official corrections.
actor BoxScoreCache {
    static let shared = BoxScoreCache()
    
    private let cacheDirectory: URL
    private var memoryCache: [String: CachedBoxScore] = [:]
    
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
        // Check memory cache first
        if let cached = memoryCache[gameId], Date().timeIntervalSince(cached.cachedAt) < 21_600 {
            return cached
        }
        
        // Check disk cache
        if let cached = loadFromDisk(gameId: gameId), Date().timeIntervalSince(cached.cachedAt) < 21_600 {
            memoryCache[gameId] = cached
            return cached
        }
        
        return nil
    }
    
    /// Saves box score to cache (both memory and disk for finished games)
    func save(gameId: String, boxScore: CachedBoxScore, isFinished: Bool) {
        guard isFinished else { return }
        if memoryCache.count >= 100 { memoryCache.removeAll() }
        memoryCache[gameId] = boxScore
        saveToDisk(gameId: gameId, boxScore: boxScore)
    }
    
    /// Checks if a finished game's box score is already cached
    func hasCached(gameId: String) -> Bool {
        return get(gameId: gameId) != nil
    }
    
    // MARK: - Disk Operations
    
    private func fileURL(for gameId: String) -> URL {
        cacheDirectory.appendingPathComponent("\(gameId).json")
    }
    
    private func fileExists(gameId: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: gameId).path)
    }
    
    private func loadFromDisk(gameId: String) -> CachedBoxScore? {
        let url = fileURL(for: gameId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedBoxScore.self, from: data)
    }
    
    private func saveToDisk(gameId: String, boxScore: CachedBoxScore) {
        let url = fileURL(for: gameId)
        guard let data = try? JSONEncoder().encode(boxScore) else { return }
        try? data.write(to: url, options: .atomic)
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
}

struct CachedPlayer: Codable {
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
    
    func toPlayer() -> Player {
        Player(
            name: name,
            nameI: nameI,
            position: position,
            points: points,
            rebounds: rebounds,
            assists: assists
        )
    }
}
