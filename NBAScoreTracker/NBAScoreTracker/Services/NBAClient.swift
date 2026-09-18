import Foundation

protocol NBAFetching {
    func scoreboard(for date: String) async throws -> [Game]
    func leaders(for game: Game) async throws -> CachedBoxScore
}

enum NBAError: LocalizedError {
    case http(Int)
    case invalidResponse
    case wrongDate

    var errorDescription: String? {
        switch self {
        case .http(403), .http(429): return "NBA is temporarily limiting requests. We'll retry automatically."
        case .http(let status): return "NBA returned an error (\(status)). We'll retry automatically."
        case .invalidResponse: return "NBA returned incomplete data. We'll retry automatically."
        case .wrongDate: return "The live scoreboard belongs to another date."
        }
    }
}

/// Transport and decoding live off the UI actor. Detail requests use a separate
/// connection pool so a slow box score can never hold up the scoreboard.
actor NBAClient: NBAFetching {
    private let session: URLSession
    private let detailSession: URLSession
    private let cache: BoxScoreCache

    init(session: URLSession? = nil, cache: BoxScoreCache = .shared) {
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
    }

    func scoreboard(for date: String) async throws -> [Game] {
        if date == ScoreDate.key() {
            do {
                let response: CDNScoreboardResponse = try await load(
                    "https://cdn.nba.com/static/json/liveData/scoreboard/todaysScoreboard_00.json",
                    using: session
                )
                guard response.scoreboard.gameDate == date else { throw NBAError.wrongDate }
                // Empty is a successful response, not a reason to hit another API.
                return try response.scoreboard.games.map { game in
                    try makeGame(id: game.gameId, status: game.gameStatus, text: game.gameStatusText,
                                 period: game.period, time: game.gameTimeUTC,
                                 home: game.homeTeam.teamTricode, homeScore: game.homeTeam.score,
                                 away: game.awayTeam.teamTricode, awayScore: game.awayTeam.score,
                                 broadcaster: game.broadcasters?.nationalTvBroadcasters?.first?.broadcasterDisplay)
                }
            } catch {
                try Task.checkCancellation()
                // The dated endpoint is also needed around the NBA's day rollover.
            }
        }
        let response: ScoreboardResponse = try await load(
            "https://stats.nba.com/stats/scoreboardv3?GameDate=\(date)&LeagueID=00", using: session
        )
        return try response.scoreboard.games.map { game in
            try makeGame(id: game.gameId, status: game.gameStatus, text: game.gameStatusText,
                         period: game.period, time: game.gameTimeUTC,
                         home: game.homeTeam.teamTricode, homeScore: game.homeTeam.score,
                         away: game.awayTeam.teamTricode, awayScore: game.awayTeam.score,
                         broadcaster: game.broadcasters?.nationalBroadcasters?.first?.broadcastDisplay
                            ?? game.broadcasters?.nationalOttBroadcasters?.first?.broadcastDisplay)
        }
    }

    func leaders(for game: Game) async throws -> CachedBoxScore {
        if game.status == .finished, let cached = await cache.get(gameId: game.id),
           cached.homeScore == game.homeTeam.score, cached.awayScore == game.awayTeam.score {
            return cached
        }
        let response: BoxscoreResponse = try await load(
            "https://cdn.nba.com/static/json/liveData/boxscore/boxscore_\(game.id).json", using: detailSession
        )
        guard let box = response.game, box.gameId == game.id,
              let home = box.homeTeam, let away = box.awayTeam,
              let homePlayers = home.players, let awayPlayers = away.players,
              !homePlayers.isEmpty, !awayPlayers.isEmpty else { throw NBAError.invalidResponse }
        let result = CachedBoxScore(
            gameId: game.id,
            homeTeam: cachedTeam(tricode: home.teamTricode ?? game.homeTeam.tricode, players: homePlayers),
            awayTeam: cachedTeam(tricode: away.teamTricode ?? game.awayTeam.tricode, players: awayPlayers),
            homeScore: home.score, awayScore: away.score
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
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NBAError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw NBAError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
        // Retrying belongs to the polling coordinator, not nested request loops.
    }

    private func makeGame(id: String, status: Int, text: String, period: Int, time: String?,
                          home: String?, homeScore: Int?, away: String?, awayScore: Int?,
                          broadcaster: String?) throws -> Game {
        guard !id.isEmpty, id.allSatisfy(\.isNumber), let state = Game.GameStatus(rawValue: status),
              let home, let away, !home.isEmpty, !away.isEmpty else { throw NBAError.invalidResponse }
        if state != .upcoming && (homeScore == nil || awayScore == nil) { throw NBAError.invalidResponse }
        let channel = broadcaster?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Game(id: id, status: state, statusText: text,
                    broadcaster: channel?.isEmpty == false ? (channel!.uppercased().contains("AMAZON") ? "Prime Video" : channel!) : "",
                    homeTeam: Team(tricode: home, score: homeScore ?? 0, leaders: []),
                    awayTeam: Team(tricode: away, score: awayScore ?? 0, leaders: []),
                    period: period, gameTimeUTC: time ?? "")
    }

    private func cachedTeam(tricode: String, players: [BoxscorePlayer]) -> CachedTeamBoxScore {
        let sorted = players.sorted {
            let a = $0.statistics, b = $1.statistics
            if (a?.points ?? 0) != (b?.points ?? 0) { return (a?.points ?? 0) > (b?.points ?? 0) }
            if (a?.reboundsTotal ?? 0) != (b?.reboundsTotal ?? 0) { return (a?.reboundsTotal ?? 0) > (b?.reboundsTotal ?? 0) }
            if (a?.assists ?? 0) != (b?.assists ?? 0) { return (a?.assists ?? 0) > (b?.assists ?? 0) }
            return ($0.name ?? "") < ($1.name ?? "")
        }
        return CachedTeamBoxScore(tricode: tricode, players: sorted.map { p in
            let s = p.statistics
            return CachedPlayer(name: p.name ?? "Unknown", nameI: p.nameI ?? "", position: p.position ?? "",
                                points: s?.points ?? 0, rebounds: s?.reboundsTotal ?? 0, assists: s?.assists ?? 0,
                                steals: s?.steals ?? 0, blocks: s?.blocks ?? 0, minutes: s?.minutes ?? "",
                                fgm: s?.fieldGoalsMade ?? 0, fga: s?.fieldGoalsAttempted ?? 0,
                                threePm: s?.threePointersMade ?? 0, threePa: s?.threePointersAttempted ?? 0,
                                ftm: s?.freeThrowsMade ?? 0, fta: s?.freeThrowsAttempted ?? 0)
        })
    }
}
