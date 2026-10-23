import Foundation
import os

protocol NBAFetching {
    // The date is a local calendar day, not an NBA schedule date.
    func scoreboard(for date: String) async throws -> [Game]
    func leaders(for game: Game) async throws -> CachedBoxScore
}

enum NBAError: LocalizedError {
    case http(Int)
    case invalidResponse
    case wrongDate
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .http(403), .http(429): return "NBA is temporarily limiting requests. We'll retry automatically."
        case .http(let status): return "NBA returned an error (\(status)). We'll retry automatically."
        case .invalidResponse: return "NBA returned incomplete data. We'll retry automatically."
        case .wrongDate: return "The live scoreboard belongs to another date."
        case .responseTooLarge: return "NBA returned unusually large data. We'll retry automatically."
        }
    }
}

// Both scoreboard feeds decode into distinct row types with the same shape; the
// shared validation in NBAClient.decodeGames below reads rows through this
// protocol so the CDN and stats paths cannot drift apart.
protocol ScoreboardGame {
    var gameId: String { get }
    var gameStatus: Int { get }
    var gameStatusText: String { get }
    var period: Int { get }
    var gameClock: String? { get }
    var gameTimeUTC: String? { get }
    var homeTricode: String? { get }
    var homeScore: Int? { get }
    var awayTricode: String? { get }
    var awayScore: Int? { get }
    var nationalBroadcaster: String? { get }
}

extension CDNGame: ScoreboardGame {
    var homeTricode: String? { homeTeam.teamTricode }
    var homeScore: Int? { homeTeam.score }
    var awayTricode: String? { awayTeam.teamTricode }
    var awayScore: Int? { awayTeam.score }
    var nationalBroadcaster: String? { broadcasters?.nationalTvBroadcasters?.first?.broadcasterDisplay }
}

extension APIGame: ScoreboardGame {
    var homeTricode: String? { homeTeam.teamTricode }
    var homeScore: Int? { homeTeam.score }
    var awayTricode: String? { awayTeam.teamTricode }
    var awayScore: Int? { awayTeam.score }
    var nationalBroadcaster: String? {
        broadcasters?.nationalBroadcasters?.first?.broadcastDisplay
            ?? broadcasters?.nationalOttBroadcasters?.first?.broadcastDisplay
    }
}

/// Transport and decoding live off the UI actor. Detail requests use a separate
/// connection pool so a slow box score can never hold up the scoreboard.
actor NBAClient: NBAFetching {
    private let session: URLSession
    private let detailSession: URLSession
    private let cache: BoxScoreCache
    private let now: () -> Date
    private var scoreboardTasks: [LeagueDate: Task<[Game], Error>] = [:]
    // The CDN live scoreboard omits national TV, which the dated stats feed has.
    // Learned per game ID so every tab shows the same broadcaster badges.
    private var broadcasters: [String: String] = [:]
    private var broadcasterAttempts: [LeagueDate: Date] = [:]
    // Debug-only WNBA override (NBA_LEAGUE=10, see AGENTS.md): repoints the whole
    // live pipeline at the WNBA's CDN for testing before the NBA season starts.
    // Release builds never read the environment and cannot enter this mode.
    private let usesWNBAEndpoints: Bool

    init(session: URLSession? = nil, cache: BoxScoreCache = .shared, now: @escaping () -> Date = Date.init) {
        func makeSession() -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            config.httpMaximumConnectionsPerHost = 4
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: config)
        }
        self.session = session ?? makeSession()
        self.detailSession = session ?? makeSession()
        self.cache = cache
        self.now = now
        #if DEBUG
        self.usesWNBAEndpoints = ProcessInfo.processInfo.environment["NBA_LEAGUE"] == "10"
        #else
        self.usesWNBAEndpoints = false
        #endif
    }

    func scoreboard(for date: String) async throws -> [Game] {
        guard let interval = ScoreDate.interval(for: date) else { throw NBAError.invalidResponse }
        let games = try await withThrowingTaskGroup(of: [Game].self) { group in
            for leagueDate in LeagueDate.covering(interval) {
                group.addTask { try await self.leagueScoreboard(for: leagueDate) }
            }
            var games: [Game] = []
            for try await fetched in group { games.append(contentsOf: fetched) }
            return games
        }
        return games.compactMap { game -> (Game, Date)? in
            guard let start = game.startDate, start >= interval.start, start < interval.end else { return nil }
            return (game, start)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id < $1.0.id
        }.map { $0.0 }
    }

    private func leagueScoreboard(for date: LeagueDate) async throws -> [Game] {
        try Task.checkCancellation()
        let task: Task<[Game], Error>
        if let existing = scoreboardTasks[date] {
            task = existing
        } else {
            task = Task {
                defer { scoreboardTasks.removeValue(forKey: date) }
                return try await loadLeagueScoreboard(for: date)
            }
            scoreboardTasks[date] = task
        }
        let games = try await task.value
        try Task.checkCancellation()
        return games
    }

    private func loadLeagueScoreboard(for date: LeagueDate) async throws -> [Game] {
        if date == LeagueDate(containing: now()) {
            do {
                let response: CDNScoreboardResponse = try await load(
                    usesWNBAEndpoints
                        ? "https://cdn.wnba.com/static/json/liveData/scoreboard/todaysScoreboard_10.json"
                        : "https://cdn.nba.com/static/json/liveData/scoreboard/todaysScoreboard_00.json",
                    using: session
                )
                guard response.scoreboard.gameDate == date.key else { throw NBAError.wrongDate }
                // Empty is a successful response, not a reason to hit another API.
                let games = try Self.decodeGames(response.scoreboard.games)
                if games.contains(where: { $0.broadcaster.isEmpty && broadcasters[$0.id] == nil }) {
                    requestBroadcasters(for: date)
                }
                return games.map { game in
                    var game = game
                    if game.broadcaster.isEmpty, let known = broadcasters[game.id] { game.broadcaster = known }
                    return game
                }
            } catch {
                try Task.checkCancellation()
                // The dated endpoint is also needed around the NBA's day rollover.
            }
        }
        let games = try await loadStatsScoreboard(for: date)
        remember(broadcastersFrom: games)
        return games
    }

    private func loadStatsScoreboard(for date: LeagueDate) async throws -> [Game] {
        let response: ScoreboardResponse = try await load(
            usesWNBAEndpoints
                ? "https://stats.nba.com/stats/scoreboardv3?GameDate=\(date.key)&LeagueID=10"
                : "https://stats.nba.com/stats/scoreboardv3?GameDate=\(date.key)&LeagueID=00",
            using: session
        )
        return try Self.decodeGames(response.scoreboard.games)
    }

    /// Best-effort and off the scoreboard path: stats.nba.com is slower and more
    /// often blocked than the CDN, so it must never delay or fail live scores.
    /// Results apply from the next refresh onward.
    private func requestBroadcasters(for date: LeagueDate) {
        let current = now()
        if let last = broadcasterAttempts[date], current.timeIntervalSince(last) >= 0,
           current.timeIntervalSince(last) < 1_800 { return }
        broadcasterAttempts = broadcasterAttempts.filter { abs(current.timeIntervalSince($0.value)) < 86_400 }
        broadcasterAttempts[date] = current
        Task {
            guard let games = try? await loadStatsScoreboard(for: date) else { return }
            remember(broadcastersFrom: games)
        }
    }

    private func remember(broadcastersFrom games: [Game]) {
        if broadcasters.count > 4 * NBAFeedLimits.games { broadcasters.removeAll() }
        for game in games where !game.broadcaster.isEmpty { broadcasters[game.id] = game.broadcaster }
    }

    func leaders(for game: Game) async throws -> CachedBoxScore {
        if game.status == .finished, let cached = await cache.get(gameId: game.id),
           cached.homeScore == game.homeTeam.score, cached.awayScore == game.awayTeam.score {
            return cached
        }
        let response: BoxscoreResponse = try await load(
            usesWNBAEndpoints
                ? "https://cdn.wnba.com/static/json/liveData/boxscore/boxscore_\(game.id).json"
                : "https://cdn.nba.com/static/json/liveData/boxscore/boxscore_\(game.id).json",
            using: detailSession
        )
        guard let box = response.game, box.gameId == game.id,
              let home = box.homeTeam, let away = box.awayTeam,
              let homePlayers = home.players, let awayPlayers = away.players,
              Self.validPlayers(homePlayers), Self.validPlayers(awayPlayers),
              home.teamTricode == nil || home.teamTricode == game.homeTeam.tricode,
              away.teamTricode == nil || away.teamTricode == game.awayTeam.tricode else { throw NBAError.invalidResponse }
        let result = CachedBoxScore(
            gameId: game.id,
            homeTeam: cachedTeam(tricode: home.teamTricode ?? game.homeTeam.tricode, players: homePlayers),
            awayTeam: cachedTeam(tricode: away.teamTricode ?? game.awayTeam.tricode, players: awayPlayers),
            homeScore: home.score, awayScore: away.score,
            progress: Self.progress(from: box)
        )
        // Never promote an in-progress box score into the final-game cache.
        if game.status == .finished, box.gameStatus == 3,
           home.score == game.homeTeam.score, away.score == game.awayTeam.score {
            await cache.save(gameId: game.id, boxScore: result, isFinished: true)
        }
        return result
    }

    private func load<T: Decodable>(_ address: String, using session: URLSession) async throws -> T {
        guard let url = URL(string: address) else { throw NBAError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.nba.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.nba.com/", forHTTPHeaderField: "Referer")
        // URLSession supplies Host, Connection and compression headers correctly.
        let data = try await fetchBoundedData(for: request, using: session)
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: data)
        // Retrying belongs to the polling coordinator, not nested request loops.
    }

    private func fetchBoundedData(for request: URLRequest, using session: URLSession) async throws -> Data {
        final class BoundedState: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var responseError: Error?
            var completed = false
            weak var task: URLSessionDataTask?
        }

        final class BoundedDelegate: NSObject, URLSessionDataDelegate {
            let state: BoundedState
            let continuation: CheckedContinuation<Data, Error>

            init(state: BoundedState, continuation: CheckedContinuation<Data, Error>) {
                self.state = state
                self.continuation = continuation
            }

            func urlSession(
                _ session: URLSession,
                dataTask: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
            ) {
                state.lock.lock()
                defer { state.lock.unlock() }
                guard let http = response as? HTTPURLResponse else {
                    state.responseError = NBAError.invalidResponse
                    completionHandler(.cancel)
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    state.responseError = NBAError.http(http.statusCode)
                    completionHandler(.cancel)
                    return
                }
                guard response.expectedContentLength <= Int64(NBAFeedLimits.responseBytes) else {
                    state.responseError = NBAError.responseTooLarge
                    completionHandler(.cancel)
                    return
                }
                state.data.reserveCapacity(min(NBAFeedLimits.responseBytes, max(0, Int(response.expectedContentLength))))
                completionHandler(.allow)
            }

            func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
                state.lock.lock()
                defer { state.lock.unlock() }
                guard state.responseError == nil else { return }
                guard state.data.count + chunk.count <= NBAFeedLimits.responseBytes else {
                    state.responseError = NBAError.responseTooLarge
                    dataTask.cancel()
                    return
                }
                state.data.append(chunk)
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                state.lock.lock()
                guard !state.completed else {
                    state.lock.unlock()
                    return
                }
                state.completed = true
                let responseError = state.responseError
                let data = state.data
                state.lock.unlock()

                if let responseError {
                    continuation.resume(throwing: responseError)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }

        let state = BoundedState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = BoundedDelegate(state: state, continuation: continuation)
                let task = session.dataTask(with: request)
                task.delegate = delegate
                state.lock.lock()
                state.task = task
                state.lock.unlock()
                if Task.isCancelled {
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            state.lock.lock()
            let task = state.task
            state.lock.unlock()
            task?.cancel()
        }
    }

    // Row validation shared by both scoreboard paths. Per-row problems are data and
    // drop only their row; structural problems are failures. A half-broken feed must
    // not read as an empty day, so rows present with zero valid games still throw —
    // only a genuinely empty array returns an empty schedule.
    static func decodeGames<Row: ScoreboardGame>(_ rows: [Row], log: Logger = Logger()) throws -> [Game] {
        guard rows.count <= NBAFeedLimits.games else { throw NBAError.invalidResponse }
        guard !rows.isEmpty else { return [] }
        var valid: [Game] = []
        for row in rows {
            do {
                valid.append(try makeGame(from: row))
            } catch NBAError.invalidResponse {
                log.warning("Dropped malformed game row (id=\(String(row.gameId.prefix(20)), privacy: .public)).")
            } catch {
                // makeGame throws nothing else today; unknown failures stay structural.
                throw error
            }
        }
        guard !valid.isEmpty else { throw NBAError.invalidResponse }
        return valid
    }

    private static func makeGame(from row: some ScoreboardGame) throws -> Game {
        guard NBAFeedLimits.isGameID(row.gameId),
              let state = Game.GameStatus(rawValue: row.gameStatus),
              let home = row.homeTricode, let away = row.awayTricode,
              NBAFeedLimits.isTricode(home), NBAFeedLimits.isTricode(away),
              NBAFeedLimits.isText(row.gameStatusText), NBAFeedLimits.isText(row.nationalBroadcaster),
              let gameTimeUTC = row.gameTimeUTC,
              NBAFeedLimits.isText(gameTimeUTC, maximumBytes: 64),
              let tipoff = ScoreDate.tipoffDate(from: gameTimeUTC) else { throw NBAError.invalidResponse }
        if state != .upcoming && (row.homeScore == nil || row.awayScore == nil) { throw NBAError.invalidResponse }
        let channel = row.nationalBroadcaster?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Both feeds pad status text with trailing spaces.
        return Game(id: row.gameId, status: state, statusText: row.gameStatusText.trimmingCharacters(in: .whitespacesAndNewlines),
                    broadcaster: channel?.isEmpty == false ? (channel!.uppercased().contains("AMAZON") ? "Prime Video" : channel!) : "",
                    homeTeam: Team(tricode: home, score: row.homeScore ?? 0, leaders: []),
                    awayTeam: Team(tricode: away, score: row.awayScore ?? 0, leaders: []),
                    period: row.period, gameTimeUTC: gameTimeUTC, startDate: tipoff,
                    isLoadingLeaders: state != .upcoming,
                    gameClock: row.gameClock.flatMap { NBAFeedLimits.isText($0, maximumBytes: 32) ? $0 : nil } ?? "")
    }

    /// Nil when the box score lacks a trustworthy game state; its leaders may
    /// still be used under the scoreboard's status.
    static func progress(from box: BoxscoreGame) -> GameProgress? {
        guard let status = box.gameStatus.flatMap(Game.GameStatus.init(rawValue:)),
              let period = box.period, (0...20).contains(period),
              let homeScore = box.homeTeam?.score, let awayScore = box.awayTeam?.score,
              (0...500).contains(homeScore), (0...500).contains(awayScore),
              NBAFeedLimits.isText(box.gameStatusText), NBAFeedLimits.isText(box.gameClock, maximumBytes: 32) else { return nil }
        return GameProgress(status: status,
                            statusText: box.gameStatusText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                            period: period, gameClock: box.gameClock ?? "",
                            homeScore: homeScore, awayScore: awayScore)
    }

    private static func hasPlayed(_ minutes: String?) -> Bool {
        guard let minutes = minutes?.trimmingCharacters(in: .whitespacesAndNewlines), !minutes.isEmpty else { return false }
        return minutes != "PT00M00.00S" && minutes != "PT0M0S" && minutes != "0:00" && minutes != "00:00" && minutes != "0"
    }

    private static func validPlayers(_ players: [BoxscorePlayer]) -> Bool {
        !players.isEmpty && players.count <= NBAFeedLimits.playersPerTeam && players.allSatisfy {
            NBAFeedLimits.isText($0.name, maximumBytes: 128)
                && NBAFeedLimits.isText($0.nameI, maximumBytes: 128)
                && NBAFeedLimits.isText($0.position, maximumBytes: 16)
                && NBAFeedLimits.isText($0.statistics?.minutes, maximumBytes: 64)
        }
    }

    private func cachedTeam(tricode: String, players: [BoxscorePlayer]) -> CachedTeamBoxScore {
        var seenIDs = Set<String>()
        let identified = players.enumerated().map { index, player in
            let baseID = player.personId.flatMap { $0 > 0 ? "nba:\($0)" : nil }
                ?? "roster:\(tricode):\(index)"
            let id = seenIDs.insert(baseID).inserted ? baseID : "\(baseID):duplicate:\(index)"
            return (id: id, player: player)
        }
        // Assign identity before sorting so changes in scoring rank do not
        // change the identity of players lacking an NBA ID.
        let sorted = identified.sorted {
            let a = $0.player.statistics, b = $1.player.statistics
            if (a?.points ?? 0) != (b?.points ?? 0) { return (a?.points ?? 0) > (b?.points ?? 0) }
            if (a?.reboundsTotal ?? 0) != (b?.reboundsTotal ?? 0) { return (a?.reboundsTotal ?? 0) > (b?.reboundsTotal ?? 0) }
            if (a?.assists ?? 0) != (b?.assists ?? 0) { return (a?.assists ?? 0) > (b?.assists ?? 0) }
            if (a?.steals ?? 0) != (b?.steals ?? 0) { return (a?.steals ?? 0) > (b?.steals ?? 0) }
            if (a?.blocks ?? 0) != (b?.blocks ?? 0) { return (a?.blocks ?? 0) > (b?.blocks ?? 0) }
            let aPlayed = Self.hasPlayed(a?.minutes), bPlayed = Self.hasPlayed(b?.minutes)
            if aPlayed != bPlayed { return aPlayed && !bPlayed }
            return ($0.player.name ?? "") < ($1.player.name ?? "")
        }
        return CachedTeamBoxScore(tricode: tricode, players: sorted.map { entry in
            let p = entry.player
            let s = p.statistics
            return CachedPlayer(id: entry.id, name: p.name ?? "Unknown", nameI: p.nameI ?? "", position: p.position ?? "",
                                points: s?.points ?? 0, rebounds: s?.reboundsTotal ?? 0, assists: s?.assists ?? 0,
                                steals: s?.steals ?? 0, blocks: s?.blocks ?? 0, minutes: s?.minutes ?? "",
                                fgm: s?.fieldGoalsMade ?? 0, fga: s?.fieldGoalsAttempted ?? 0,
                                threePm: s?.threePointersMade ?? 0, threePa: s?.threePointersAttempted ?? 0,
                                ftm: s?.freeThrowsMade ?? 0, fta: s?.freeThrowsAttempted ?? 0)
        })
    }
}
