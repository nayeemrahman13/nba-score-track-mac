import Foundation

/// Caches box score data for finished games to avoid repeated API calls.
/// Finished games are cached permanently since their data never changes.
actor BoxScoreCache {
    static let shared = BoxScoreCache()
    
    private let cacheDirectory: URL
    private var memoryCache: [String: CachedBoxScore] = [:]
    
    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDir.appendingPathComponent("NBAScoreTracker/boxscores", isDirectory: true)
        
        // Create cache directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Public API
    
    /// Returns cached box score if available, nil otherwise
    func get(gameId: String) -> CachedBoxScore? {
        // Check memory cache first
        if let cached = memoryCache[gameId] {
            return cached
        }
        
        // Check disk cache
        if let cached = loadFromDisk(gameId: gameId) {
            memoryCache[gameId] = cached
            return cached
        }
        
        return nil
    }
    
    /// Saves box score to cache (both memory and disk for finished games)
    func save(gameId: String, boxScore: CachedBoxScore, isFinished: Bool) {
        memoryCache[gameId] = boxScore
        
        // Only persist to disk for finished games
        if isFinished {
            saveToDisk(gameId: gameId, boxScore: boxScore)
        }
    }
    
    /// Checks if a finished game's box score is already cached
    func hasCached(gameId: String) -> Bool {
        return memoryCache[gameId] != nil || fileExists(gameId: gameId)
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
        try? data.write(to: url)
    }
}

// MARK: - Cached Data Model

struct CachedBoxScore: Codable {
    let gameId: String
    let homeTeam: CachedTeamBoxScore
    let awayTeam: CachedTeamBoxScore
    let cachedAt: Date
    
    init(gameId: String, homeTeam: CachedTeamBoxScore, awayTeam: CachedTeamBoxScore) {
        self.gameId = gameId
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
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
