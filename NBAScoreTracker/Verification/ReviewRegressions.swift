// Standalone regression checks for PR #1; no Xcode test target required.
import Foundation

private actor GatedNBA: NBAFetching {
    private(set) var dates: [String] = []
    private var blocked = true
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var started: CheckedContinuation<Void, Never>?

    func scoreboard(for date: String) async throws -> [Game] {
        dates.append(date)
        if blocked {
            await withCheckedContinuation { continuation in
                gates.append(continuation)
                if gates.count == ScoreDate.trackedOffsets.count { started?.resume(); started = nil }
            }
        }
        return []
    }
    func leaders(for game: Game) async throws -> CachedBoxScore { throw NBAError.invalidResponse }
    func waitForFirstBatch() async {
        if gates.count == ScoreDate.trackedOffsets.count { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        blocked = false
        gates.forEach { $0.resume() }
        gates.removeAll()
    }
}

private actor ScheduleNBA: NBAFetching {
    private var failedDate: String?
    private(set) var requested: [String] = []
    let emptyDate: String

    init(emptyDate: String) { self.emptyDate = emptyDate }
    func fail(on date: String?) { failedDate = date }
    func scoreboard(for date: String) async throws -> [Game] {
        requested.append(date)
        if date == failedDate { throw URLError(.notConnectedToInternet) }
        if date == emptyDate { return [] }
        return [Game(id: date, status: .upcoming, statusText: "Scheduled", broadcaster: "",
                     homeTeam: Team(tricode: "NYK", score: 0, leaders: []),
                     awayTeam: Team(tricode: "BOS", score: 0, leaders: []), period: 0,
                     gameTimeUTC: "\(date)T23:00:00Z")]
    }
    func leaders(for game: Game) async throws -> CachedBoxScore { throw NBAError.invalidResponse }
}

private actor EnrichmentNBA: NBAFetching {
    private var gamesByDate: [String: [Game]] = [:]
    private var boxesByGame: [String: CachedBoxScore] = [:]
    private var blockedGameId: String?
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var leaderCalls = 0

    func setGames(_ games: [Game], for date: String) { gamesByDate[date] = games }
    func setBox(_ box: CachedBoxScore, for gameId: String) { boxesByGame[gameId] = box }
    func block(gameId: String) { blockedGameId = gameId }

    func waitForLeaderFetch() async {
        if blockedContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func releaseLeaderFetch() {
        blockedGameId = nil
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    func scoreboard(for date: String) async throws -> [Game] {
        gamesByDate[date] ?? []
    }

    func leaders(for game: Game) async throws -> CachedBoxScore {
        leaderCalls += 1
        if game.id == blockedGameId {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
                startedContinuation?.resume()
                startedContinuation = nil
            }
        }
        guard let box = boxesByGame[game.id] else { throw NBAError.invalidResponse }
        return box
    }
}

private final class FixtureProtocol: URLProtocol {
    static var body = ""
    static var bodies: [String: String] = [:]
    static var statuses: [String: Int] = [:]
    static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let date = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "GameDate" })?.value ?? "cdn"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.statuses[date] ?? 200, httpVersion: nil, headerFields: Self.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((Self.bodies[date] ?? Self.body).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
private struct ReviewRegressions {
    @MainActor
    static func main() async throws {
        try await verifyLocalDates()

        // Verify the actual public lifecycle API during a suspended request,
        // rather than testing rollover only after a previous refresh completes.
        for dayOffset in [0, 1] {
            var clock = Date()
            let client = GatedNBA()
            let service = NBAService(client: client, now: { clock })
            let first = Task { await service.refreshAll() }
            await client.waitForFirstBatch()
            clock = Calendar.current.date(byAdding: .day, value: dayOffset, to: clock)!
            service.resume()
            await client.release()
            await first.value
            let dates = await client.dates
            precondition(dates.count == ScoreDate.trackedOffsets.count * 2, "Lifecycle event was lost or refreshes duplicated")
            precondition(Set(dates.suffix(ScoreDate.trackedOffsets.count)) == Set(ScoreDate.trackedOffsets.map { ScoreDate.key(offset: $0, now: clock) }))
            precondition(service.day == ScoreDate.key(now: clock))
            precondition(service.games[ScoreDate.key(offset: 1, now: clock)] != nil)
            precondition(!service.isLoading)
            print("PASS: \(dayOffset == 0 ? "wake" : "rollover") during an in-flight refresh completes a follow-up batch before returning")
        }

        let client = GatedNBA()
        let service = NBAService(client: client)
        let first = Task { await service.refreshAll() }
        await client.waitForFirstBatch()
        let joined = Task { await service.refreshAll() }
        await client.release()
        await first.value
        await joined.value
        let dates = await client.dates
        precondition(dates.count == ScoreDate.trackedOffsets.count, "Ordinary joined refresh bypassed freshness")
        print("PASS: ordinary concurrent refreshes still coalesce")

        // Explicit calendar dates exercise the three-day horizon across a year
        // boundary, including an empty middle day and a partial network failure.
        let reference = ScoreDate.date(for: "2026-12-30")!
        let scheduleClient = ScheduleNBA(emptyDate: "2027-01-01")
        let schedule = NBAService(client: scheduleClient, now: { reference })
        await schedule.refreshAll()
        precondition(schedule.upcomingDates == ["2026-12-31", "2027-01-01", "2027-01-02"])
        let requested = await scheduleClient.requested
        precondition(Set(requested) == Set(["2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02"]))
        precondition(schedule.games["2027-01-01"]?.isEmpty == true)
        precondition(schedule.games["2027-01-02"]?.count == 1)
        let previousUpdate = schedule.updatedAt["2027-01-02"]
        await scheduleClient.fail(on: "2027-01-02")
        await schedule.refreshAll()
        precondition(schedule.games["2027-01-02"]?.count == 1)
        precondition(schedule.updatedAt["2027-01-02"] == previousUpdate)
        precondition(schedule.errors.count == 1 && schedule.errors["2027-01-02"] != nil)
        precondition(schedule.games["2026-12-31"]?.count == 1 && schedule.games["2027-01-01"]?.isEmpty == true)
        print("PASS: three-day Upcoming horizon crosses year boundaries and preserves each day's empty/error/cached state")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nba-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BoxScoreCache(directory: directory)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = NBAClient(session: URLSession(configuration: config), cache: cache)
        let game = Game(id: "0022600001", status: .live, statusText: "Q4", broadcaster: "",
                        homeTeam: Team(tricode: "NYK", score: 100, leaders: []),
                        awayTeam: Team(tricode: "BOS", score: 90, leaders: []), period: 4, gameTimeUTC: "")
        func payload(players: [[String: Any]]) throws -> String {
            let team: [String: Any] = ["teamTricode": "NYK", "score": 100, "players": players]
            var away = team
            away["teamTricode"] = "BOS"
            away["score"] = 90
            let box: [String: Any] = ["gameId": game.id, "gameStatus": 2, "homeTeam": team, "awayTeam": away]
            return String(data: try JSONSerialization.data(withJSONObject: ["game": box]), encoding: .utf8)!
        }
        FixtureProtocol.body = try payload(players: [
            ["personId": 10, "name": "Same Name", "statistics": ["points": 20]],
            ["personId": 20, "name": "Same Name", "statistics": ["points": 10]],
            ["statistics": ["points": 0]]
        ])
        let original = try await api.leaders(for: game)
        let ids = original.homeTeam.leaders.map(\.id)
        precondition(Set(ids).count == 3 && ids[0] == "nba:10" && ids[1] == "nba:20")
        FixtureProtocol.body = try payload(players: [
            ["personId": 10, "name": "Same Name", "statistics": ["points": 20]],
            ["personId": 20, "name": "Same Name", "statistics": ["points": 30]],
            ["statistics": ["points": 40]]
        ])
        let reordered = try await api.leaders(for: game)
        precondition(reordered.homeTeam.leaders.map(\.id) == [ids[2], ids[1], ids[0]])
        await cache.save(gameId: game.id, boxScore: reordered, isFinished: true)
        let disk = await BoxScoreCache(directory: directory).get(gameId: game.id)
        precondition(disk?.homeTeam.leaders.map(\.id) == reordered.homeTeam.leaders.map(\.id))
        print("PASS: duplicate display names have stable IDs across rank changes and disk-cache reloads")

        FixtureProtocol.body = try payload(players: [[:], [:], [:]])
        let unnamed = try await api.leaders(for: game)
        precondition(Set(unnamed.homeTeam.leaders.map(\.id)).count == 3)
        FixtureProtocol.body = try payload(players: [["personId": 10], ["personId": 10], [:]])
        let duplicateIDs = try await api.leaders(for: game)
        precondition(Set(duplicateIDs.homeTeam.leaders.map(\.id)).count == 3)
        print("PASS: missing names and malformed duplicate NBA IDs remain unique")

        var oldTeam = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unnamed.homeTeam)) as! [String: Any]
        oldTeam["players"] = (oldTeam["players"] as! [[String: Any]]).map { row in
            var row = row
            row.removeValue(forKey: "id")
            return row
        }
        let legacy = try JSONDecoder().decode(CachedTeamBoxScore.self, from: JSONSerialization.data(withJSONObject: oldTeam))
        let legacyIDs = legacy.leaders.map(\.id)
        precondition(Set(legacyIDs).count == 3 && legacyIDs == legacy.leaders.map(\.id))
        print("PASS: existing cache files without player IDs decode with unique stable row fallbacks")

        // Audit Medium #1: one malformed game row must drop only itself. Per-row
        // problems are data; structural problems (rows present, zero valid) throw.
        let cdnRows = [
            CDNGame(gameId: "0022600002", gameStatus: 2, gameStatusText: "Q4", period: 4, gameTimeUTC: "2026-10-07T23:00:00Z",
                    homeTeam: CDNTeam(teamTricode: "NYK", score: 100), awayTeam: CDNTeam(teamTricode: "BOS", score: 90),
                    broadcasters: CDNBroadcasters(nationalTvBroadcasters: [CDNBroadcaster(broadcasterDisplay: "TNT")],
                                                  nationalRadioBroadcasters: nil, homeTvBroadcasters: nil, awayTvBroadcasters: nil)),
            CDNGame(gameId: "0022600003", gameStatus: 1, gameStatusText: "7:00 pm ET", period: 0, gameTimeUTC: "2026-10-07T23:00:00Z",
                    homeTeam: CDNTeam(teamTricode: "LAL", score: nil), awayTeam: CDNTeam(teamTricode: "GSW", score: nil),
                    broadcasters: nil)
        ]
        let decodedCDN = try NBAClient.decodeGames(cdnRows)
        precondition(decodedCDN.map(\.id) == ["0022600002", "0022600003"], "All-valid rows must decode unchanged")
        precondition(decodedCDN[0].status == .live && decodedCDN[0].homeTeam.tricode == "NYK" && decodedCDN[0].broadcaster == "TNT")
        precondition(decodedCDN[1].status == .upcoming)
        let apiRows = [
            APIGame(gameId: "0022600004", gameStatus: 3, gameStatusText: "Final", period: 4, gameTimeUTC: "2026-10-07T23:00:00Z",
                    homeTeam: APITeam(teamTricode: "MIA", score: 112), awayTeam: APITeam(teamTricode: "BOS", score: 108),
                    broadcasters: Broadcasters(nationalBroadcasters: [Broadcaster(broadcastDisplay: "ABC")], nationalOttBroadcasters: nil)),
            APIGame(gameId: "0022600005", gameStatus: 1, gameStatusText: "7:30 pm ET", period: 0, gameTimeUTC: "2026-10-07T23:00:00Z",
                    homeTeam: APITeam(teamTricode: "DAL", score: nil), awayTeam: APITeam(teamTricode: "PHX", score: nil),
                    broadcasters: nil)
        ]
        let decodedAPI = try NBAClient.decodeGames(apiRows)
        precondition(decodedAPI.map(\.id) == ["0022600004", "0022600005"], "Stats-feed rows must decode through the same helper")
        precondition(decodedAPI[0].status == .finished && decodedAPI[0].broadcaster == "ABC")
        print("PASS: all-valid rows decode unchanged on both the CDN and stats shapes")

        // The audit's realistic trigger: a game that just flipped live and is
        // published momentarily with null scores.
        let liveFlip = CDNGame(gameId: "0022600006", gameStatus: 2, gameStatusText: "Q1", period: 1, gameTimeUTC: "2026-10-07T23:00:00Z",
                               homeTeam: CDNTeam(teamTricode: "CLE", score: nil), awayTeam: CDNTeam(teamTricode: "DET", score: nil),
                               broadcasters: nil)
        let badStatus = CDNGame(gameId: "0022600007", gameStatus: 9, gameStatusText: "??", period: 0, gameTimeUTC: "2026-10-07T23:00:00Z",
                                homeTeam: CDNTeam(teamTricode: "SAS", score: nil), awayTeam: CDNTeam(teamTricode: "MEM", score: nil),
                                broadcasters: nil)
        let surviving = try NBAClient.decodeGames([cdnRows[0], liveFlip, badStatus, cdnRows[1]])
        precondition(surviving.map(\.id) == ["0022600002", "0022600003"], "A malformed row must drop only itself")
        print("PASS: malformed game rows are skipped and logged while their siblings survive")

        let missingTipoff = CDNGame(gameId: "0022600020", gameStatus: 1, gameStatusText: "TBD", period: 0, gameTimeUTC: nil,
                                   homeTeam: CDNTeam(teamTricode: "MIA", score: nil), awayTeam: CDNTeam(teamTricode: "NYK", score: nil),
                                   broadcasters: nil)
        let datedSiblings = try NBAClient.decodeGames([cdnRows[0], missingTipoff])
        precondition(datedSiblings.map(\.id) == ["0022600002"])
        do {
            _ = try NBAClient.decodeGames([missingTipoff])
            preconditionFailure("A feed with no usable tipoff must fail rather than become an empty local schedule")
        } catch NBAError.invalidResponse { }
        print("PASS: missing tipoffs drop only their row and never turn an unusable feed into an empty schedule")

        let allMalformed = [
            APIGame(gameId: "0022600008", gameStatus: 9, gameStatusText: "?", period: 0, gameTimeUTC: "2026-10-07T23:00:00Z",
                    homeTeam: APITeam(teamTricode: "OKC", score: nil), awayTeam: APITeam(teamTricode: "UTA", score: nil), broadcasters: nil),
            APIGame(gameId: "0022600009", gameStatus: 2, gameStatusText: "Q2", period: 2, gameTimeUTC: "2026-10-07T23:00:00Z",
                    homeTeam: APITeam(teamTricode: "ORL", score: nil), awayTeam: APITeam(teamTricode: "TOR", score: nil), broadcasters: nil)
        ]
        do {
            _ = try NBAClient.decodeGames(allMalformed)
            precondition(false, "Rows with zero valid games must throw, not render an empty day")
        } catch NBAError.invalidResponse { /* expected structural failure */ }
        catch { precondition(false, "decodeGames threw an unexpected error: \(error)") }
        print("PASS: rows present with zero valid games still throw invalidResponse")

        let emptyCDN = try NBAClient.decodeGames([CDNGame]())
        precondition(emptyCDN.isEmpty, "An empty games array is a successful empty schedule")
        let emptyAPI = try NBAClient.decodeGames([APIGame]())
        precondition(emptyAPI.isEmpty)
        print("PASS: an empty games array stays a successful empty schedule")

        // Supply the live league date and leave other overlapping schedules empty.
        let today = ScoreDate.key()
        let currentLeagueDate = LeagueDate(containing: Date()).key
        let currentTipoff = ISO8601DateFormatter().string(from: Date())
        FixtureProtocol.body = """
        {"scoreboard": {"gameDate": "\(currentLeagueDate)", "games": [
          {"gameId": "0022600010", "gameStatus": 2, "gameStatusText": "Q3", "period": 3, "gameTimeUTC": "\(currentTipoff)",
           "homeTeam": {"teamTricode": "OKC", "score": 71}, "awayTeam": {"teamTricode": "DEN", "score": 68}},
          {"gameId": "0022600011", "gameStatus": 2, "gameStatusText": "Q1", "period": 1, "gameTimeUTC": "\(currentTipoff)",
           "homeTeam": {"teamTricode": "SAC", "score": null}, "awayTeam": {"teamTricode": "POR", "score": null}}
        ]}}
        """
        FixtureProtocol.bodies = ["cdn": FixtureProtocol.body, currentLeagueDate: FixtureProtocol.body]
        FixtureProtocol.body = scheduleBody(date: "", games: [])
        let cdnFetched = try await api.scoreboard(for: today)
        precondition(cdnFetched.map(\.id) == ["0022600010"], "The CDN path must drop malformed rows through the real fetch")
        print("PASS: the CDN fetch path drops malformed rows while their siblings survive")

        FixtureProtocol.body = """
        {"scoreboard": {"gameDate": "2000-01-01", "games": [
          {"gameId": "0022600012", "gameStatus": 3, "gameStatusText": "Final", "period": 4, "gameTimeUTC": "\(currentTipoff)",
           "homeTeam": {"teamTricode": "MIL", "score": 121}, "awayTeam": {"teamTricode": "CHI", "score": 113}},
          {"gameId": "0022600013", "gameStatus": 9, "gameStatusText": "??", "period": 0, "gameTimeUTC": "\(currentTipoff)",
           "homeTeam": {"teamTricode": "UTA", "score": null}, "awayTeam": {"teamTricode": "NOP", "score": null}}
        ]}}
        """
        FixtureProtocol.bodies = ["cdn": FixtureProtocol.body, currentLeagueDate: FixtureProtocol.body]
        FixtureProtocol.body = scheduleBody(date: "", games: [])
        let fallbackFetched = try await api.scoreboard(for: today)
        precondition(fallbackFetched.map(\.id) == ["0022600012"], "The dated-stats fallback must drop malformed rows too")
        print("PASS: the dated-stats fallback path drops malformed rows while their siblings survive")

        FixtureProtocol.bodies = [:]
        FixtureProtocol.body = """
        {"game": {"gameId": "\(game.id)", "gameStatus": 3, "gameStatusText": "Final  ", "period": 4, "gameClock": "PT00M00.00S",
          "homeTeam": {"teamTricode": "NYK", "score": 100, "players": [{"personId": 1, "name": "A"}]},
          "awayTeam": {"teamTricode": "BOS", "score": 90, "players": [{"personId": 2, "name": "B"}]}}}
        """
        let finalBox = try await api.leaders(for: game)
        precondition(finalBox.progress == GameProgress(status: .finished, statusText: "Final", period: 4,
                                                       gameClock: "PT00M00.00S", homeScore: 100, awayScore: 90))
        precondition(GameProgress.seconds(fromClock: "PT05M42.50S") == 342.5 && GameProgress.seconds(fromClock: "") == nil)
        print("PASS: box scores carry their own status, period, clock and score")

        // The CDN live scoreboard omits national TV; it is filled from the stats
        // feed in the background and never blocks or fails the CDN result.
        let broadcastAPI = NBAClient(session: URLSession(configuration: config), cache: cache)
        FixtureProtocol.bodies = [
            "cdn": """
            {"scoreboard": {"gameDate": "\(currentLeagueDate)", "games": [
              {"gameId": "0022600030", "gameStatus": 2, "gameStatusText": "Q3        ", "period": 3, "gameTimeUTC": "\(currentTipoff)",
               "homeTeam": {"teamTricode": "OKC", "score": 71}, "awayTeam": {"teamTricode": "DEN", "score": 68}}]}}
            """,
            currentLeagueDate: """
            {"scoreboard": {"gameDate": "\(currentLeagueDate)", "games": [
              {"gameId": "0022600030", "gameStatus": 2, "gameStatusText": "Q3", "period": 3, "gameTimeUTC": "\(currentTipoff)",
               "homeTeam": {"teamTricode": "OKC", "score": 71}, "awayTeam": {"teamTricode": "DEN", "score": 68},
               "broadcasters": {"nationalBroadcasters": [{"broadcastDisplay": "ESPN"}]}}]}}
            """
        ]
        FixtureProtocol.body = scheduleBody(date: "", games: [])
        var broadcastGames: [Game] = []
        for _ in 0..<100 {
            broadcastGames = try await broadcastAPI.scoreboard(for: today)
            if broadcastGames.first?.broadcaster == "ESPN" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(broadcastGames.map(\.id) == ["0022600030"] && broadcastGames[0].broadcaster == "ESPN")
        precondition(broadcastGames[0].statusText == "Q3", "Padded feed status text must be trimmed")
        print("PASS: Today's CDN games get national broadcasters from the stats feed and trimmed status text")
        try await verifySecurityBoundaries()
        try await verifyBoxScoreProgress()
    }

    @MainActor
    private static func verifySecurityBoundaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nba-security-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
            FixtureProtocol.body = ""
            FixtureProtocol.bodies = [:]
            FixtureProtocol.statuses = [:]
            FixtureProtocol.headers = [:]
        }
        FixtureProtocol.bodies = [:]
        FixtureProtocol.statuses = [:]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = NBAClient(session: URLSession(configuration: config), cache: BoxScoreCache(directory: directory))
        let game = Game(id: "0022600001", status: .live, statusText: "Q1", broadcaster: "",
                        homeTeam: Team(tricode: "NYK", score: 10, leaders: []),
                        awayTeam: Team(tricode: "BOS", score: 9, leaders: []), period: 1, gameTimeUTC: "")

        FixtureProtocol.headers = ["Content-Length": "\(NBAFeedLimits.responseBytes + 1)"]
        FixtureProtocol.body = "{}"
        do {
            _ = try await api.leaders(for: game)
            preconditionFailure("An oversized declared response was accepted")
        } catch NBAError.responseTooLarge {}
        FixtureProtocol.headers = ["Content-Length": "1"]
        FixtureProtocol.body = String(repeating: " ", count: NBAFeedLimits.responseBytes + 1)
        do {
            _ = try await api.leaders(for: game)
            preconditionFailure("An oversized streamed response was accepted")
        } catch NBAError.responseTooLarge {}
        print("PASS: oversized HTTP responses are rejected with both truthful and dishonest Content-Length headers")
        FixtureProtocol.headers = [:]

        func row(id: String = "0022600001", home: String = "NYK", status: String = "Q1") -> CDNGame {
            CDNGame(gameId: id, gameStatus: 2, gameStatusText: status, period: 1, gameTimeUTC: "2026-10-08T04:00:00Z",
                    homeTeam: CDNTeam(teamTricode: home, score: 10), awayTeam: CDNTeam(teamTricode: "BOS", score: 9), broadcasters: nil)
        }
        let valid = try NBAClient.decodeGames([row(), row(id: String(repeating: "1", count: 1024)),
                                              row(id: "１２３"), row(id: "../../escape"), row(home: "../logo"),
                                              row(status: String(repeating: "🏀", count: 65))])
        precondition(valid.map(\.id) == ["0022600001"])
        precondition(Team(tricode: "../logo", score: 0, leaders: []).logoURL == nil)
        do {
            _ = try NBAClient.decodeGames((0...NBAFeedLimits.games).map { row(id: String(format: "%010d", $0)) })
            preconditionFailure("An oversized game collection was accepted")
        } catch NBAError.invalidResponse {}
        print("PASS: game IDs, logo paths, UTF-8 text, and schedule counts are bounded at the feed boundary")

        func boxBody(players: [[String: Any]]) throws -> String {
            let box: [String: Any] = ["gameId": game.id, "gameStatus": 2,
                "homeTeam": ["teamTricode": "NYK", "score": 10, "players": players],
                "awayTeam": ["teamTricode": "BOS", "score": 9, "players": [["name": "Valid Player"]]]]
            return String(data: try JSONSerialization.data(withJSONObject: ["game": box]), encoding: .utf8)!
        }
        for players in [Array(repeating: ["name": "Player"], count: NBAFeedLimits.playersPerTeam + 1),
                        [["name": String(repeating: "x", count: 129)]]] {
            FixtureProtocol.body = try boxBody(players: players)
            do {
                _ = try await api.leaders(for: game)
                preconditionFailure("Oversized player data was accepted")
            } catch NBAError.invalidResponse {}
        }
        FixtureProtocol.body = try boxBody(players: [["name": "Valid Player"]])
        let acceptedBox = try await api.leaders(for: game)
        precondition(acceptedBox.homeTeam.leaders.first?.name == "Valid Player")
        print("PASS: oversized player collections and names fail while a valid box score still loads")

        let team = CachedTeamBoxScore(tricode: "NYK", players: [])
        func box(_ id: String) -> CachedBoxScore { CachedBoxScore(gameId: id, homeTeam: team, awayTeam: team) }
        let old = Date().addingTimeInterval(-BoxScoreCache.lifetime - 60)
        for index in 0..<120 {
            let url = directory.appendingPathComponent(String(format: "%010d.json", index))
            try JSONEncoder().encode(box(String(format: "%010d", index))).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let cache = BoxScoreCache(directory: directory)
        let missing = await cache.get(gameId: "9999999999")
        let remainingExpiredFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(missing == nil && remainingExpiredFiles.isEmpty)
        for index in 0...BoxScoreCache.maximumEntries {
            let id = String(format: "%010d", index)
            await cache.save(gameId: id, boxScore: box(id), isFinished: true)
        }
        let retained = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(retained.count == BoxScoreCache.maximumEntries)
        print("PASS: cache maintenance deletes expired files and bounds the retained file count")

        let largeDirectory = directory.appendingPathComponent("large", isDirectory: true)
        try FileManager.default.createDirectory(at: largeDirectory, withIntermediateDirectories: true)
        for index in 0..<100 {
            let id = String(format: "%010d", index)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(box(id))) as! [String: Any]
            object["padding"] = String(repeating: "x", count: 200_000)
            try JSONSerialization.data(withJSONObject: object).write(to: largeDirectory.appendingPathComponent("\(id).json"))
        }
        let largeCache = BoxScoreCache(directory: largeDirectory)
        _ = await largeCache.get(gameId: "9999999999")
        let largeFiles = try FileManager.default.contentsOfDirectory(at: largeDirectory, includingPropertiesForKeys: [.fileSizeKey])
        let totalBytes = try largeFiles.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        precondition(totalBytes <= BoxScoreCache.maximumDiskBytes && largeFiles.count < 100)
        print("PASS: cache pruning enforces the total disk byte budget")

        let id = "9999999999"
        let url = largeDirectory.appendingPathComponent("\(id).json")
        try Data(repeating: 32, count: BoxScoreCache.maximumEntryBytes + 1).write(to: url)
        let oversized = await largeCache.get(gameId: id)
        precondition(oversized == nil && !FileManager.default.fileExists(atPath: url.path))
        try JSONEncoder().encode(box("1234567890")).write(to: url)
        let mismatched = await largeCache.get(gameId: id)
        precondition(mismatched == nil && !FileManager.default.fileExists(atPath: url.path))
        await largeCache.save(gameId: "../escape", boxScore: box("../escape"), isFinished: true)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape.json").path))
        print("PASS: oversized and mismatched disk records are removed and cache paths cannot escape their directory")

        // Verify leader tie-breaking prefers active players and secondary stats over bench players.
        FixtureProtocol.body = try boxBody(players: [
            ["personId": 1, "name": "Alpha Bench", "position": "G", "statistics": ["points": 0, "reboundsTotal": 0, "assists": 0, "minutes": "PT00M00.00S"]],
            ["personId": 2, "name": "Zeta Starter", "position": "F", "statistics": ["points": 0, "reboundsTotal": 0, "assists": 0, "minutes": "PT04M12.00S",
                                                                                    "fieldGoalsMade": 0, "fieldGoalsAttempted": 2, "steals": 1]]
        ])
        let tieBroken = try await api.leaders(for: game)
        let firstLeader = tieBroken.homeTeam.leaders.first!
        precondition(firstLeader.id == "nba:2" && firstLeader.formattedMinutes == "4 MIN" && firstLeader.detailTooltip.contains("1 STL"))
        print("PASS: player leader tie-breaking prefers active players and preserves detailed box-score stats")

        // Verify queued follow-up enrichment when a game turns live during an in-flight leader batch.
        let enrichDate = "2026-10-18"
        let enrichClock = ScoreDate.date(for: enrichDate)!
        let enrichClient = EnrichmentNBA()
        let game1 = Game(id: "0022600101", status: .live, statusText: "Q2", broadcaster: "",
                         homeTeam: Team(tricode: "NYK", score: 50, leaders: []),
                         awayTeam: Team(tricode: "BOS", score: 48, leaders: []),
                         period: 2, gameTimeUTC: "2026-10-18T23:00:00Z")
        var game2 = Game(id: "0022600102", status: .upcoming, statusText: "7:30 pm ET", broadcaster: "",
                         homeTeam: Team(tricode: "LAL", score: 0, leaders: []),
                         awayTeam: Team(tricode: "GSW", score: 0, leaders: []),
                         period: 0, gameTimeUTC: "2026-10-18T23:30:00Z")
        let playerLeader = CachedPlayer(id: "nba:99", name: "Star Player", nameI: "S. Player", position: "G",
                                        points: 25, rebounds: 5, assists: 7, steals: 2, blocks: 1,
                                        minutes: "PT32M00.00S", fgm: 9, fga: 15, threePm: 4, threePa: 8, ftm: 3, fta: 3)
        let teamBox = CachedTeamBoxScore(tricode: "NYK", players: [playerLeader])
        await enrichClient.setGames([game1, game2], for: enrichDate)
        await enrichClient.setBox(CachedBoxScore(gameId: game1.id, homeTeam: teamBox, awayTeam: teamBox), for: game1.id)
        await enrichClient.setBox(CachedBoxScore(gameId: game2.id, homeTeam: teamBox, awayTeam: teamBox), for: game2.id)
        await enrichClient.block(gameId: game1.id)

        let enrichService = NBAService(client: enrichClient, now: { enrichClock })
        await enrichService.refreshAll()
        await enrichClient.waitForLeaderFetch()
        precondition(enrichService.games[enrichDate]?.first(where: { $0.id == game1.id })?.isLoadingLeaders == true)

        // Game 2 flips from upcoming to live while Game 1's leader request is still in flight.
        game2 = Game(id: "0022600102", status: .live, statusText: "Q1", broadcaster: "",
                     homeTeam: Team(tricode: "LAL", score: 4, leaders: []),
                     awayTeam: Team(tricode: "GSW", score: 2, leaders: []),
                     period: 1, gameTimeUTC: "2026-10-18T23:30:00Z")
        await enrichClient.setGames([game1, game2], for: enrichDate)
        await enrichService.refreshAll()
        await enrichClient.releaseLeaderFetch()
        for _ in 0..<50 {
            if enrichService.games[enrichDate]?.allSatisfy({ !$0.isLoadingLeaders && !$0.homeTeam.leaders.isEmpty }) == true {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let finalGames = enrichService.games[enrichDate] ?? []
        precondition(finalGames.count == 2 && finalGames.allSatisfy { !$0.isLoadingLeaders && $0.homeTeam.leaders.first?.points == 25 })
        print("PASS: leader enrichment tracks loading state and runs a queued follow-up pass when games turn live mid-batch")
    }

    /// Reproduces a real feed lag: both scoreboards stayed at 4th Qtr 0:44 for
    /// minutes while the box score reached Final.
    @MainActor
    private static func verifyBoxScoreProgress() async throws {
        func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(condition(), message)
        }
        let date = "2026-10-19"
        let client = EnrichmentNBA()
        let service = NBAService(client: client, now: { ScoreDate.date(for: date)! })
        let id = "0022600201"
        func scoreboardGame(_ status: Game.GameStatus, _ text: String, clock: String, home: Int, away: Int) -> Game {
            Game(id: id, status: status, statusText: text, broadcaster: "",
                 homeTeam: Team(tricode: "PHI", score: home, leaders: []), awayTeam: Team(tricode: "CLE", score: away, leaders: []),
                 period: 4, gameTimeUTC: "2026-10-19T23:00:00Z", gameClock: clock)
        }
        func box(_ progress: GameProgress, points: Int) -> CachedBoxScore {
            let player = CachedPlayer(id: "nba:\(points)", name: "P\(points)", nameI: "", position: "", points: points, rebounds: 0,
                                      assists: 0, steals: 0, blocks: 0, minutes: "", fgm: 0, fga: 0, threePm: 0, threePa: 0, ftm: 0, fta: 0)
            let team = CachedTeamBoxScore(tricode: "PHI", players: [player])
            return CachedBoxScore(gameId: id, homeTeam: team, awayTeam: team,
                                  homeScore: progress.homeScore, awayScore: progress.awayScore, progress: progress)
        }
        var shown: Game? { service.games[date]?.first }
        let staleRow = scoreboardGame(.live, "4th Qtr", clock: "PT00M44.00S", home: 110, away: 102)
        let final = GameProgress(status: .finished, statusText: "Final", period: 4, gameClock: "PT00M00.00S", homeScore: 114, awayScore: 106)
        let staleLive = GameProgress(status: .live, statusText: "Q4 :44.0", period: 4, gameClock: "PT00M44.00S", homeScore: 110, awayScore: 102)

        await client.setGames([staleRow], for: date)
        await client.setBox(box(final, points: 25), for: id)
        await service.refreshAll()
        try await waitUntil("A box score further along must supply score and status") {
            shown?.status == .finished && shown?.homeTeam.score == 114 && shown?.homeTeam.leaders.first?.points == 25
        }
        precondition(shown?.statusText == "Final" && shown?.awayTeam.score == 106 && shown?.isLoadingLeaders == false)
        try await Task.sleep(nanoseconds: 50_000_000)

        await client.block(gameId: id)
        await service.refreshAll()
        await client.waitForLeaderFetch()
        precondition(shown?.status == .finished && shown?.homeTeam.score == 114, "A lagging scoreboard refresh must not move the score backward")
        await client.releaseLeaderFetch()
        let calls = await client.leaderCalls
        try await Task.sleep(nanoseconds: 50_000_000)

        await client.setBox(box(staleLive, points: 1), for: id)
        await service.refreshAll()
        for _ in 0..<200 where await client.leaderCalls == calls { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(shown?.status == .finished && shown?.homeTeam.score == 114 && shown?.homeTeam.leaders.first?.points == 25,
                     "A box score behind the displayed state must not apply its score or leaders")
        print("PASS: a box score further along than a lagging scoreboard supplies the score and never moves it backward")

        await client.setGames([scoreboardGame(.finished, "Final", clock: "PT00M00.00S", home: 115, away: 106)], for: date)
        await client.setBox(box(final, points: 25), for: id)
        await service.refreshAll()
        try await waitUntil("Once both sources are final, the scoreboard's official result wins") {
            shown?.status == .finished && shown?.homeTeam.score == 115
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(shown?.homeTeam.score == 115)
        print("PASS: once both sources are final, the scoreboard's official result wins")
    }

    @MainActor
    private static func verifyLocalDates() async throws {
        let originalTimeZone = NSTimeZone.default
        defer {
            NSTimeZone.default = originalTimeZone
            FixtureProtocol.bodies = [:]
            FixtureProtocol.statuses = [:]
            FixtureProtocol.body = ""
        }
        NSTimeZone.default = TimeZone(identifier: "Asia/Hong_Kong")!
        var clock = ISO8601DateFormatter().date(from: "2026-10-07T23:30:00Z")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = NBAClient(session: URLSession(configuration: config), now: { clock })
        FixtureProtocol.body = scheduleBody(date: "", games: [])
        FixtureProtocol.bodies = [
            "2026-10-06": scheduleBody(date: "2026-10-06", games: [("26", "2026-10-06T23:00:00Z")]),
            "2026-10-07": scheduleBody(date: "2026-10-07", games: [("27", "2026-10-07T12:00:00Z"), ("29", "2026-10-07T23:00:00Z")]),
            "2026-10-08": scheduleBody(date: "2026-10-08", games: [("33", "2026-10-08T12:00:00Z"), ("30", "2026-10-08T23:00:00Z")]),
            "2026-10-09": scheduleBody(date: "2026-10-09", games: [("31", "2026-10-09T12:00:00Z")]),
            "2026-10-10": scheduleBody(date: "2026-10-10", games: [("43", "2026-10-10T23:00:00Z")])
        ]
        FixtureProtocol.bodies["cdn"] = FixtureProtocol.bodies["2026-10-07"]
        let today = try await api.scoreboard(for: "2026-10-08")
        precondition(today.map(\.id) == ["29", "33"], "Hong Kong Today must contain games from both overlapping NBA schedules")
        let yesterday = try await api.scoreboard(for: "2026-10-07")
        precondition(yesterday.map(\.id) == ["26", "27"])
        let upcoming = try await api.scoreboard(for: "2026-10-09")
        precondition(upcoming.map(\.id) == ["30", "31"])
        print("PASS: Hong Kong Yesterday, Today, and Upcoming group games by local tipoff date")

        FixtureProtocol.bodies["cdn"] = scheduleBody(date: "2000-01-01", games: [])
        let fallback = try await api.scoreboard(for: "2026-10-08")
        precondition(fallback.map(\.id) == ["29", "33"], "A stale CDN day must fall back to the matching league date")
        FixtureProtocol.bodies["cdn"] = FixtureProtocol.bodies["2026-10-07"]
        print("PASS: CDN date validation uses the league day and preserves the dated fallback")

        let service = NBAService(client: api, now: { clock })
        await service.refreshAll()
        precondition(service.errors.isEmpty && service.games["2026-10-08"]?.map(\.id) == ["29", "33"])
        precondition(service.games["2026-10-10"]?.isEmpty == true && service.games["2026-10-11"]?.map(\.id) == ["43"])
        let retainedUpdate = service.updatedAt["2026-10-08"]
        FixtureProtocol.statuses["2026-10-08"] = 503
        await service.refreshAll()
        precondition(Set(service.errors.keys) == ["2026-10-08", "2026-10-09"])
        precondition(service.games["2026-10-08"]?.map(\.id) == ["29", "33"] && service.updatedAt["2026-10-08"] == retainedUpdate)
        FixtureProtocol.statuses = [:]
        await service.refreshAll()
        precondition(service.errors.isEmpty)
        print("PASS: an overlapping schedule failure retains local-day scores and recovers independently")

        clock = ISO8601DateFormatter().date(from: "2026-10-08T23:30:00Z")!
        service.resume()
        await service.refreshAll()
        precondition(service.day == "2026-10-09" && service.games["2026-10-09"]?.map(\.id) == ["30", "31"])
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        service.resume()
        await service.refreshAll()
        precondition(service.day == "2026-10-08" && service.games["2026-10-08"]?.map(\.id) == ["33", "30"])
        print("PASS: rollover and a timezone change regroup real client results before the refresh returns")

        FixtureProtocol.bodies = [
            "2026-10-07": scheduleBody(date: "2026-10-07", games: [("50", "2026-10-08T06:59:59.999Z"), ("51", "2026-10-08T07:00:00Z")]),
            "2026-10-08": scheduleBody(date: "2026-10-08", games: [("52", "2026-10-08T06:00:00Z")])
        ]
        let pacific = try await api.scoreboard(for: "2026-10-07")
        precondition(pacific.map(\.id) == ["52", "50"], "Pacific dates must include the next Eastern day and exclude exact local midnight")
        print("PASS: Pacific dates include both Eastern schedules and use an exclusive midnight boundary")

        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        for (date, start, last, end, hours) in [
            ("2026-03-08", "2026-03-08T05:00:00Z", "2026-03-09T03:59:59.999Z", "2026-03-09T04:00:00Z", 23.0),
            ("2026-11-01", "2026-11-01T04:00:00Z", "2026-11-02T04:59:59.999Z", "2026-11-02T05:00:00Z", 25.0)
        ] {
            let interval = ScoreDate.interval(for: date)!
            precondition(interval.duration == hours * 3600)
            precondition(LeagueDate.covering(interval).map(\.key) == [date])
            FixtureProtocol.bodies = [date: scheduleBody(date: date, games: [("60", start), ("61", last), ("62", end)])]
            let games = try await api.scoreboard(for: date)
            precondition(games.map(\.id) == ["60", "61"])
        }
        print("PASS: 23-hour and 25-hour DST days preserve both midnight boundaries")

        NSTimeZone.default = TimeZone(identifier: "Asia/Hong_Kong")!
        FixtureProtocol.bodies = [
            "2026-12-31": scheduleBody(date: "2026-12-31", games: [("70", "2026-12-31T23:00:00Z")]),
            "2027-01-01": scheduleBody(date: "2027-01-01", games: [("71", "2027-01-01T23:00:00Z")])
        ]
        let newYear = try await api.scoreboard(for: "2027-01-01")
        precondition(newYear.map(\.id) == ["70"])
        precondition(LeagueDate.covering(ScoreDate.interval(for: "2027-01-01")!).map(\.key) == ["2026-12-31", "2027-01-01"])
        precondition(ScoreDate.interval(for: "2026-02-30") == nil)
        print("PASS: local dates cross year boundaries and reject invalid date keys")
    }

    private static func scheduleBody(date: String, games: [(String, String)]) -> String {
        let rows = games.map { id, utc in
            """
            {"gameId":"\(id)","gameStatus":1,"gameStatusText":"Scheduled","period":0,"gameTimeUTC":"\(utc)",
             "homeTeam":{"teamTricode":"IND","score":0},"awayTeam":{"teamTricode":"MIN","score":0}}
            """
        }.joined(separator: ",")
        return "{\"scoreboard\":{\"gameDate\":\"\(date)\",\"games\":[\(rows)]}}"
    }
}
