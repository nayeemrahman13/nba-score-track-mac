import Foundation

/// Persists a bounded, validated snapshot of the latest scoreboards so cold
/// launches render immediately instead of flashing "Loading scores…".
final class ScoreboardSnapshotCache: @unchecked Sendable {
    struct Snapshot: Codable, Equatable, Sendable {
        let league: String
        let savedAt: Date
        let games: [String: [Game]]
        let updatedAt: [String: Date]
        let progressByGame: [String: GameProgress]?

        init(
            league: String,
            savedAt: Date,
            games: [String: [Game]],
            updatedAt: [String: Date],
            progressByGame: [String: GameProgress]? = nil
        ) {
            self.league = league
            self.savedAt = savedAt
            self.games = games
            self.updatedAt = updatedAt
            self.progressByGame = progressByGame
        }
    }

    static let shared = ScoreboardSnapshotCache()
    static let lifetime: TimeInterval = 6 * 3600
    static let maximumBytes = 512 * 1024
    static let defaultDebounceInterval: TimeInterval = 10

    private struct PendingPayload: Sendable {
        let games: [String: [Game]]
        let updatedAt: [String: Date]
        let progressByGame: [String: GameProgress]
    }

    private final class PendingBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var payload: PendingPayload?

        func set(_ next: PendingPayload) {
            lock.lock()
            payload = next
            lock.unlock()
        }

        func take() -> PendingPayload? {
            lock.lock()
            defer { lock.unlock() }
            let next = payload
            payload = nil
            return next
        }
    }

    private let fileURL: URL
    private let league: String
    private let pendingBuffer = PendingBuffer()
    private let writer: Writer

    init(
        directory: URL? = nil,
        league: String? = nil,
        debounceInterval: TimeInterval = defaultDebounceInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let resolvedDir: URL
        if let directory {
            resolvedDir = directory
        } else {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            resolvedDir = cachesDir.appendingPathComponent("NBAScoreTracker", isDirectory: true)
        }
        self.fileURL = resolvedDir.appendingPathComponent("snapshot-v1.json")

        let resolvedLeague: String
        if let league {
            resolvedLeague = league
        } else {
            #if DEBUG
            resolvedLeague = ProcessInfo.processInfo.environment["NBA_LEAGUE"] == "10" ? "wnba" : "nba"
            #else
            resolvedLeague = "nba"
            #endif
        }
        self.league = resolvedLeague
        self.writer = Writer(
            directory: resolvedDir,
            fileURL: self.fileURL,
            league: resolvedLeague,
            debounceInterval: debounceInterval,
            pendingBuffer: pendingBuffer,
            now: now
        )
    }

    /// Synchronous read used once during cold-start `NBAService` initialization.
    /// Rejects symlinks, oversized files, expired snapshots, league mismatches,
    /// and any malformed game or progress records.
    func load(now: Date = Date()) -> Snapshot? {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            return nil
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumBytes + 1),
              data.count <= Self.maximumBytes else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        let age = now.timeIntervalSince(decoded.savedAt)
        guard age >= 0, age < Self.lifetime else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard decoded.league == league else { return nil }
        guard Self.isValid(decoded) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return decoded
    }

    func scheduleSave(
        games: [String: [Game]],
        updatedAt: [String: Date],
        progressByGame: [String: GameProgress] = [:]
    ) {
        pendingBuffer.set(PendingPayload(games: games, updatedAt: updatedAt, progressByGame: progressByGame))
        Task {
            await writer.armDebounce()
        }
    }

    /// Flushes any pending debounced snapshot immediately (primarily for tests).
    func flush() async {
        await writer.flush()
    }

    private static func isValid(_ snapshot: Snapshot) -> Bool {
        guard snapshot.games.count <= ScoreDate.trackedOffsets.count * 2 else { return false }
        var validGameIDs = Set<String>()
        for (date, games) in snapshot.games {
            guard ScoreDate.interval(for: date) != nil,
                  games.count <= NBAFeedLimits.games else { return false }
            var seenIDs = Set<String>()
            for game in games {
                guard NBAFeedLimits.isGameID(game.id),
                      seenIDs.insert(game.id).inserted,
                      NBAFeedLimits.isTricode(game.homeTeam.tricode),
                      NBAFeedLimits.isTricode(game.awayTeam.tricode),
                      (0...20).contains(game.period),
                      (0...500).contains(game.homeTeam.score),
                      (0...500).contains(game.awayTeam.score),
                      NBAFeedLimits.isText(game.statusText),
                      NBAFeedLimits.isText(game.broadcaster),
                      NBAFeedLimits.isText(game.gameClock, maximumBytes: 32),
                      NBAFeedLimits.isText(game.gameTimeUTC, maximumBytes: 64),
                      ScoreDate.tipoffDate(from: game.gameTimeUTC) != nil,
                      game.homeTeam.leaders.count <= 3,
                      game.awayTeam.leaders.count <= 3 else { return false }
                validGameIDs.insert(game.id)
            }
        }
        if let progressByGame = snapshot.progressByGame {
            for (id, progress) in progressByGame {
                guard NBAFeedLimits.isGameID(id),
                      validGameIDs.contains(id),
                      (0...20).contains(progress.period),
                      (0...500).contains(progress.homeScore),
                      (0...500).contains(progress.awayScore),
                      NBAFeedLimits.isText(progress.statusText),
                      NBAFeedLimits.isText(progress.gameClock, maximumBytes: 32) else { return false }
            }
        }
        return true
    }

    private actor Writer {
        private let directory: URL
        private let fileURL: URL
        private let league: String
        private let debounceInterval: TimeInterval
        private let pendingBuffer: PendingBuffer
        private let now: @Sendable () -> Date
        private let encoder = JSONEncoder()
        private var debounceTask: Task<Void, Never>?

        init(
            directory: URL,
            fileURL: URL,
            league: String,
            debounceInterval: TimeInterval,
            pendingBuffer: PendingBuffer,
            now: @escaping @Sendable () -> Date
        ) {
            self.directory = directory
            self.fileURL = fileURL
            self.league = league
            self.debounceInterval = debounceInterval
            self.pendingBuffer = pendingBuffer
            self.now = now
        }

        func armDebounce() {
            guard debounceTask == nil else { return }
            let delay = debounceInterval
            debounceTask = Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                await self?.writePending()
            }
        }

        func flush() {
            debounceTask?.cancel()
            debounceTask = nil
            writePending()
        }

        private func writePending() {
            debounceTask = nil
            guard let next = pendingBuffer.take() else { return }
            guard !next.games.isEmpty else { return }
            let snapshot = Snapshot(
                league: league,
                savedAt: now(),
                games: next.games,
                updatedAt: next.updatedAt,
                progressByGame: next.progressByGame
            )
            guard let data = try? encoder.encode(snapshot),
                  data.count <= ScoreboardSnapshotCache.maximumBytes else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
