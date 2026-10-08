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

private final class FixtureProtocol: URLProtocol {
    static var body = ""
    static var bodies: [String: String] = [:]
    static var statuses: [String: Int] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let date = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "GameDate" })?.value ?? "cdn"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.statuses[date] ?? 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
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
            let box: [String: Any] = ["gameId": game.id, "gameStatus": 2, "homeTeam": team, "awayTeam": team]
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
