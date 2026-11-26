// Standalone regression checks for PR #1; no Xcode test target required.
import AppKit
import Combine
import CoreGraphics
import Foundation

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ date: Date) { self.value = date }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class MockNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var satisfied: Bool
    private var handler: (@Sendable (Bool) -> Void)?

    init(isSatisfied: Bool = true) { self.satisfied = isSatisfied }

    var isSatisfied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        handler = onChange
        lock.unlock()
    }

    func stop() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    func setSatisfied(_ next: Bool) {
        lock.lock()
        let changed = satisfied != next
        satisfied = next
        let cb = handler
        lock.unlock()
        if changed { cb?(next) }
    }
}

private actor GatedNBA: NBAFetching {
    private let expectedBatchSize: Int
    private(set) var dates: [String] = []
    private var blocked = true
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var started: CheckedContinuation<Void, Never>?

    init(expectedBatchSize: Int = 2) { self.expectedBatchSize = expectedBatchSize }

    func scoreboard(for date: String) async throws -> [Game] {
        dates.append(date)
        if blocked {
            await withCheckedContinuation { continuation in
                gates.append(continuation)
                if gates.count == expectedBatchSize { started?.resume(); started = nil }
            }
        }
        return []
    }
    func leaders(for game: Game) async throws -> CachedBoxScore { throw NBAError.invalidResponse }
    func waitForFirstBatch() async {
        if gates.count >= expectedBatchSize { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        blocked = false
        gates.forEach { $0.resume() }
        gates.removeAll()
    }
}

private actor SelectiveGateNBA: NBAFetching {
    private var blockedDates: Set<String> = []
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var waitTarget: String?
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private(set) var requested: [String] = []

    func block(date: String) { blockedDates.insert(date) }

    func waitForBlocked(_ date: String) async {
        if continuations[date] != nil { return }
        waitTarget = date
        await withCheckedContinuation { waitContinuation = $0 }
    }

    func release(date: String) {
        blockedDates.remove(date)
        continuations.removeValue(forKey: date)?.resume()
    }

    func scoreboard(for date: String) async throws -> [Game] {
        requested.append(date)
        if blockedDates.contains(date) {
            await withCheckedContinuation { cont in
                continuations[date] = cont
                if waitTarget == date {
                    waitContinuation?.resume()
                    waitContinuation = nil
                    waitTarget = nil
                }
            }
        }
        return [Game(id: "0022600999", status: .upcoming, statusText: "7:00 pm ET", broadcaster: "",
                     homeTeam: Team(tricode: "NYK", score: 0, leaders: []),
                     awayTeam: Team(tricode: "BOS", score: 0, leaders: []),
                     period: 0, gameTimeUTC: "\(date)T23:00:00Z")]
    }

    func leaders(for game: Game) async throws -> CachedBoxScore { throw NBAError.invalidResponse }
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
    private var blockedGameIds: Set<String> = []
    private var blockedContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var waitTargetCount: Int = 1
    private(set) var scoreboardCalls = 0
    private(set) var leaderCalls = 0
    private(set) var leaderOrder: [String] = []

    func setGames(_ games: [Game], for date: String) { gamesByDate[date] = games }
    func setBox(_ box: CachedBoxScore, for gameId: String) { boxesByGame[gameId] = box }
    func block(gameId: String) { blockedGameIds.insert(gameId) }
    func block(gameIds: [String]) { blockedGameIds.formUnion(gameIds) }
    func resetLeaderTracking() { leaderCalls = 0; leaderOrder.removeAll() }

    func waitForLeaderFetch(count: Int = 1) async {
        if blockedContinuations.count >= count { return }
        waitTargetCount = count
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func releaseLeaderFetch(gameId: String? = nil) {
        if let gameId {
            blockedGameIds.remove(gameId)
            blockedContinuations.removeValue(forKey: gameId)?.resume()
        } else {
            blockedGameIds.removeAll()
            let continuations = Array(blockedContinuations.values)
            blockedContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }
    }

    func scoreboard(for date: String) async throws -> [Game] {
        scoreboardCalls += 1
        return gamesByDate[date] ?? []
    }

    func leaders(for game: Game) async throws -> CachedBoxScore {
        leaderCalls += 1
        leaderOrder.append(game.id)
        if blockedGameIds.contains(game.id) {
            await withCheckedContinuation { continuation in
                blockedContinuations[game.id] = continuation
                if blockedContinuations.count >= waitTargetCount {
                    startedContinuation?.resume()
                    startedContinuation = nil
                }
            }
        }
        guard let box = boxesByGame[game.id] else { throw NBAError.invalidResponse }
        return box
    }
}

private final class FixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var body = ""
    static var bodies: [String: String] = [:]
    static var rawBodies: [String: Data] = [:]
    static var statuses: [String: Int] = [:]
    static var headers: [String: String] = [:]
    static var requestCounts: [String: Int] = [:]
    static var lastIfNoneMatch: [String: String] = [:]
    static var lastIfModifiedSince: [String: String] = [:]
    static var honorConditionalHeaders = false
    static var gatedPath: String?
    static var gateEnteredFlag = false
    static var gateRelease: DispatchSemaphore?

    static func configureGate(path: String?, release: DispatchSemaphore?) {
        lock.lock()
        gatedPath = path
        gateEnteredFlag = false
        gateRelease = release
        lock.unlock()
    }

    static var isGateEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gateEnteredFlag
    }

    static func count(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[key] ?? 0
    }

    static func conditionalHeaders(for key: String) -> (etag: String?, modified: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (lastIfNoneMatch[key], lastIfModifiedSince[key])
    }

    static func resetCounts() {
        lock.lock()
        defer { lock.unlock() }
        requestCounts.removeAll()
        lastIfNoneMatch.removeAll()
        lastIfModifiedSince.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let date = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "GameDate" })?.value ?? "cdn"
        let pathName = request.url?.lastPathComponent ?? ""
        let ifNoneMatch = request.value(forHTTPHeaderField: "If-None-Match")
        let ifModifiedSince = request.value(forHTTPHeaderField: "If-Modified-Since")
        Self.lock.lock()
        Self.requestCounts[date, default: 0] += 1
        if let ifNoneMatch { Self.lastIfNoneMatch[date] = ifNoneMatch }
        if let ifModifiedSince { Self.lastIfModifiedSince[date] = ifModifiedSince }
        let honorConditional = Self.honorConditionalHeaders
        let configuredStatus = Self.statuses[pathName] ?? Self.statuses[date] ?? 200
        let configuredHeaders = Self.headers
        let rawPayload = Self.rawBodies[pathName] ?? Self.rawBodies[date]
        let textPayload = Self.bodies[pathName] ?? Self.bodies[date] ?? Self.body
        let shouldGate = (Self.gatedPath == pathName && ifNoneMatch != nil)
        if shouldGate { Self.gateEnteredFlag = true }
        let release = Self.gateRelease
        Self.lock.unlock()

        let deliver = { [self] in
            if honorConditional,
               configuredStatus == 200,
               let expectedETag = configuredHeaders["ETag"],
               let expectedMod = configuredHeaders["Last-Modified"],
               ifNoneMatch == expectedETag,
               ifModifiedSince == expectedMod {
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 304, httpVersion: nil, headerFields: configuredHeaders)!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }

            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: configuredStatus, httpVersion: nil, headerFields: configuredHeaders)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: rawPayload ?? Data(textPayload.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if shouldGate {
            DispatchQueue.global().async {
                release?.wait()
                deliver()
            }
        } else {
            deliver()
        }
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
        let foregroundOffsets = [0, -1]
        for dayOffset in [0, 1] {
            var clock = Date()
            let client = GatedNBA(expectedBatchSize: foregroundOffsets.count)
            let service = NBAService(client: client, now: { clock }, networkMonitor: MockNetworkMonitor())
            service.setPopoverVisible(true)
            defer { service.setPopoverVisible(false) }
            let first = Task { await service.refreshAll() }
            await client.waitForFirstBatch()
            clock = Calendar.current.date(byAdding: .day, value: dayOffset, to: clock)!
            service.resume()
            await client.release()
            await first.value
            let dates = await client.dates
            precondition(dates.count == foregroundOffsets.count * 2, "Lifecycle event was lost or refreshes duplicated (got \(dates.count))")
            precondition(Set(dates.suffix(foregroundOffsets.count)) == Set(foregroundOffsets.map { ScoreDate.key(offset: $0, now: clock) }))
            precondition(service.day == ScoreDate.key(now: clock))
            precondition(service.games[ScoreDate.key(offset: -1, now: clock)] != nil)
            precondition(service.games[ScoreDate.key(offset: 1, now: clock)] == nil, "Future days must stay on-demand until selected")
            precondition(!service.isLoading)
            print("PASS: \(dayOffset == 0 ? "wake" : "rollover") during an in-flight refresh completes a follow-up batch before returning")
        }

        let client = GatedNBA(expectedBatchSize: foregroundOffsets.count)
        let service = NBAService(client: client, networkMonitor: MockNetworkMonitor())
        let first = Task { await service.refreshAll() }
        await client.waitForFirstBatch()
        let joined = Task { await service.refreshAll() }
        await client.release()
        await first.value
        await joined.value
        let dates = await client.dates
        precondition(dates.count == foregroundOffsets.count, "Ordinary joined refresh bypassed freshness")
        print("PASS: ordinary concurrent refreshes still coalesce")

        // Explicit calendar dates exercise the three-day horizon across a year
        // boundary (loaded on-demand), including an empty middle day and a partial network failure.
        let reference = ScoreDate.date(for: "2026-12-30")!
        let scheduleClient = ScheduleNBA(emptyDate: "2027-01-01")
        let schedule = NBAService(client: scheduleClient, now: { reference }, networkMonitor: MockNetworkMonitor())
        await schedule.refreshAll()
        precondition(schedule.upcomingDates == ["2026-12-31", "2027-01-01", "2027-01-02"])
        let initialRequested = await scheduleClient.requested
        precondition(Set(initialRequested) == Set(["2026-12-29", "2026-12-30"]),
                     "Initial foreground refresh should load only Today and Yesterday, not unselected future days")
        for offset in [1, 2, 3] {
            schedule.selectDate(offset: offset)
            await schedule.refreshAll()
        }
        let requested = await scheduleClient.requested
        precondition(Set(requested) == Set(["2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02"]))
        precondition(schedule.games["2027-01-01"]?.isEmpty == true)
        precondition(schedule.games["2027-01-02"]?.count == 1)
        let previousUpdate = schedule.updatedAt["2027-01-02"]
        await scheduleClient.fail(on: "2027-01-02")
        schedule.selectDate(offset: 3)
        await schedule.refreshAll()
        precondition(schedule.games["2027-01-02"]?.count == 1)
        precondition(schedule.updatedAt["2027-01-02"] == previousUpdate)
        precondition(schedule.errors.count == 1 && schedule.errors["2027-01-02"] != nil)
        precondition(schedule.games["2026-12-31"]?.count == 1 && schedule.games["2027-01-01"]?.isEmpty == true)
        print("PASS: three-day Upcoming horizon loads on-demand across year boundaries and preserves each day's empty/error/cached state")

        for offset in [1, 2, 3] {
            var clock = reference
            let dayClient = ScheduleNBA(emptyDate: "")
            let dayService = NBAService(client: dayClient, now: { clock }, networkMonitor: MockNetworkMonitor())
            await dayService.refreshAll()
            let initialRequests = await dayClient.requested.count
            clock = clock.addingTimeInterval(61)
            dayService.selectDate(offset: offset)
            await dayService.refreshAll(force: false)
            let refreshed = await dayClient.requested
            precondition(Set(refreshed.dropFirst(initialRequests)) == Set([
                ScoreDate.key(now: clock), ScoreDate.key(offset: offset, now: clock)
            ]), "Only Today and the selected future day should refresh")
        }
        print("PASS: each future day refreshes independently on-demand when selected in the day strip")

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
        try await verifyPhaseOneOptimizations()
        try await verifyPhaseTwoLogoCache()
        try await verifyPhaseThreeLifecycleAndLanes()
        try await verifyPhaseFourCDNAndSnapshot()
        try await verifyReviewFindingRegressions()
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
    private static func verifyPhaseOneOptimizations() async throws {
        func waitUntil(_ message: String, _ condition: () async -> Bool) async throws {
            for _ in 0..<200 {
                if await condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure(message)
        }
        func makePlayer(_ id: String, points: Int) -> CachedPlayer {
            CachedPlayer(id: id, name: "Player \(id)", nameI: "P. \(id)", position: "G",
                         points: points, rebounds: 5, assists: 4, steals: 1, blocks: 0,
                         minutes: "PT30M00.00S", fgm: 8, fga: 14, threePm: 2, threePa: 5, ftm: 2, fta: 2)
        }
        func makeFinalBox(id: String, home: Int, away: Int, points: Int) -> CachedBoxScore {
            let homeTeam = CachedTeamBoxScore(tricode: "NYK", players: [makePlayer("nba:1", points: points)])
            let awayTeam = CachedTeamBoxScore(tricode: "BOS", players: [makePlayer("nba:2", points: points)])
            let progress = GameProgress(status: .finished, statusText: "Final", period: 4,
                                        gameClock: "PT00M00.00S", homeScore: home, awayScore: away)
            return CachedBoxScore(gameId: id, homeTeam: homeTeam, awayTeam: awayTeam,
                                  homeScore: home, awayScore: away, progress: progress)
        }

        // 1. Settled final games are skipped on subsequent polls, re-enriched on official score change or TTL expiry.
        let date = "2026-10-20"
        var clock = ScoreDate.date(for: date)!
        let settledClient = EnrichmentNBA()
        let settledID = "0022600301"
        let settledGame = Game(id: settledID, status: .finished, statusText: "Final", broadcaster: "",
                               homeTeam: Team(tricode: "NYK", score: 105, leaders: []),
                               awayTeam: Team(tricode: "BOS", score: 98, leaders: []),
                               period: 4, gameTimeUTC: "2026-10-20T23:00:00Z", gameClock: "PT00M00.00S")
        await settledClient.setGames([settledGame], for: date)
        await settledClient.setBox(makeFinalBox(id: settledID, home: 105, away: 98, points: 28), for: settledID)
        let settledService = NBAService(client: settledClient, now: { clock })
        await settledService.refreshAll()
        try await waitUntil("Settled final should enrich on first load") {
            await settledClient.leaderCalls == 1 && settledService.games[date]?.first?.homeTeam.leaders.first?.points == 28
        }
        try await Task.sleep(nanoseconds: 40_000_000)

        // Track objectWillChange on an unchanged refresh (same frozen clock, same games).
        var emissions = 0
        let cancellable = settledService.objectWillChange.sink { _ in emissions += 1 }
        await settledService.refreshAll()
        try await Task.sleep(nanoseconds: 50_000_000)
        cancellable.cancel()
        let settledCalls = await settledClient.leaderCalls
        precondition(settledCalls == 1, "Settled final game must be skipped on subsequent polls")
        // Expect only isLoading/loadingDates transitions (no redundant day, games, updatedAt, or errors emissions).
        precondition(emissions <= 8, "Unchanged refresh should guard redundant @Published emissions (got \(emissions))")

        // Official score correction invalidates settled state and triggers re-enrichment.
        let correctedGame = Game(id: settledID, status: .finished, statusText: "Final", broadcaster: "",
                                 homeTeam: Team(tricode: "NYK", score: 106, leaders: []),
                                 awayTeam: Team(tricode: "BOS", score: 98, leaders: []),
                                 period: 4, gameTimeUTC: "2026-10-20T23:00:00Z", gameClock: "PT00M00.00S")
        await settledClient.setGames([correctedGame], for: date)
        await settledClient.setBox(makeFinalBox(id: settledID, home: 106, away: 98, points: 29), for: settledID)
        await settledService.refreshAll()
        try await waitUntil("Official score change must trigger re-enrichment") {
            await settledClient.leaderCalls == 2 && settledService.games[date]?.first?.homeTeam.leaders.first?.points == 29
        }
        try await Task.sleep(nanoseconds: 40_000_000)

        // Advancing past BoxScoreCache.lifetime re-enriches even with unchanged final score.
        clock = clock.addingTimeInterval(BoxScoreCache.lifetime + 60)
        let expiredDate = ScoreDate.key(now: clock)
        if expiredDate == date {
            await settledService.refreshAll()
            try await waitUntil("Expired settled final must re-enrich after TTL") {
                await settledClient.leaderCalls == 3
            }
        }
        print("PASS: settled final games are skipped until official score change or TTL expiry, with diffed @Published updates")

        // 2. Priority enrichment puts expanded live -> live -> expanded final -> other finals, including dynamic re-prioritization.
        let prioDate = "2026-10-21"
        let prioClock = ScoreDate.date(for: prioDate)!
        let prioClient = EnrichmentNBA()
        func makePrioGame(_ id: String, status: Game.GameStatus) -> Game {
            Game(id: id, status: status, statusText: status == .live ? "Q3" : "Final", broadcaster: "",
                 homeTeam: Team(tricode: "NYK", score: 80, leaders: []),
                 awayTeam: Team(tricode: "BOS", score: 78, leaders: []),
                 period: status == .live ? 3 : 4, gameTimeUTC: "2026-10-21T23:00:00Z")
        }
        let prioGames = [
            makePrioGame("0022600401", status: .finished), // f1
            makePrioGame("0022600402", status: .finished), // f2
            makePrioGame("0022600403", status: .finished), // f3
            makePrioGame("0022600404", status: .live),     // l1
            makePrioGame("0022600405", status: .live)      // l2 (expanded)
        ]
        await prioClient.setGames(prioGames, for: prioDate)
        for g in prioGames {
            await prioClient.setBox(makeFinalBox(id: g.id, home: 80, away: 78, points: 20), for: g.id)
        }
        await prioClient.block(gameIds: ["0022600405", "0022600404", "0022600401"])

        let prioService = NBAService(client: prioClient, now: { prioClock })
        prioService.setExpandedGames(["0022600405"])
        await prioService.refreshAll()
        await prioClient.waitForLeaderFetch(count: 3)
        let firstThree = Set(await prioClient.leaderOrder.prefix(3))
        precondition(firstThree == Set(["0022600405", "0022600404", "0022600401"]),
                     "First 3 enrichment slots must prioritize expanded live, live, then first final (got \(firstThree))")

        // Dynamically expand f3 before releasing a slot: f3 should be picked ahead of f2.
        prioService.setExpandedGames(["0022600405", "0022600403"])
        await prioClient.releaseLeaderFetch(gameId: "0022600405")
        try await waitUntil("Dynamically expanded f3 must jump ahead of f2") {
            await prioClient.leaderOrder.count >= 4
        }
        let fourth = await prioClient.leaderOrder[3]
        precondition(fourth == "0022600403", "Expected dynamically expanded f3 next, got \(fourth)")
        await prioClient.releaseLeaderFetch()
        try await waitUntil("All 5 games should finish enriching") {
            await prioClient.leaderOrder.count == 5
        }
        print("PASS: box-score enrichment prioritizes expanded live and live games ahead of finals, including dynamic expansion")

        // 3. Broadcaster negative cache avoids 30-minute repeat stats calls for local-only games.
        let originalTZ = NSTimeZone.default
        defer {
            NSTimeZone.default = originalTZ
            FixtureProtocol.body = ""
            FixtureProtocol.bodies = [:]
            FixtureProtocol.statuses = [:]
            FixtureProtocol.headers = [:]
            FixtureProtocol.resetCounts()
        }
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let broadcastClock = MutableClock(ISO8601DateFormatter().date(from: "2026-10-22T22:00:00Z")!)
        let leagueDate = LeagueDate(containing: broadcastClock.now).key
        let localDate = ScoreDate.key(now: broadcastClock.now)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let negAPI = NBAClient(session: URLSession(configuration: config), now: { broadcastClock.now })
        let localOnlyBody = """
        {"scoreboard": {"gameDate": "\(leagueDate)", "games": [
          {"gameId": "0022600501", "gameStatus": 2, "gameStatusText": "Q2", "period": 2,
           "gameTimeUTC": "2026-10-22T23:00:00Z",
           "homeTeam": {"teamTricode": "NYK", "score": 55}, "awayTeam": {"teamTricode": "BOS", "score": 52}}]}}
        """
        FixtureProtocol.resetCounts()
        FixtureProtocol.body = scheduleBody(date: "", games: [])
        FixtureProtocol.bodies = ["cdn": localOnlyBody, leagueDate: localOnlyBody]
        _ = try await negAPI.scoreboard(for: localDate)
        try await waitUntil("Initial background broadcaster stats fetch should fire once") {
            FixtureProtocol.count(for: leagueDate) == 1
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Advance 35 minutes (> 30 min attempt throttle, < 6 h negative cache TTL): stats must not be called again.
        broadcastClock.advance(by: 35 * 60)
        _ = try await negAPI.scoreboard(for: localDate)
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(FixtureProtocol.count(for: leagueDate) == 1,
                     "Local-only game should stay negatively cached past 30 minutes (count=\(FixtureProtocol.count(for: leagueDate)))")

        // Advance past 6-hour negative TTL: stats check should run again.
        broadcastClock.advance(by: 6 * 3600)
        _ = try await negAPI.scoreboard(for: localDate)
        try await waitUntil("Negative broadcaster cache should expire after 6 hours") {
            FixtureProtocol.count(for: leagueDate) == 2
        }
        print("PASS: broadcaster negative cache suppresses repeat stats calls for local-only games until TTL expiry")

        // 4. BoxScoreCache debounced pruning still enforces disk byte budget immediately on save().
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nba-p1-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let diskCache = BoxScoreCache(directory: dir)
        let padPlayer = CachedPlayer(id: "nba:1", name: String(repeating: "a", count: 120), nameI: "P", position: "G",
                                     points: 10, rebounds: 5, assists: 5, steals: 1, blocks: 1,
                                     minutes: "PT30M00.00S", fgm: 4, fga: 8, threePm: 1, threePa: 3, ftm: 1, fta: 1)
        let bigPlayers = Array(repeating: padPlayer, count: 350) // ~170 KB JSON per file
        let bigTeam = CachedTeamBoxScore(tricode: "NYK", players: bigPlayers)
        for index in 0..<95 {
            let id = String(format: "%010d", index)
            let entry = CachedBoxScore(gameId: id, homeTeam: bigTeam, awayTeam: bigTeam)
            await diskCache.save(gameId: id, boxScore: entry, isFinished: true)
        }
        let savedFiles = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        let savedBytes = try savedFiles.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        precondition(savedBytes <= BoxScoreCache.maximumDiskBytes && savedFiles.count < 95,
                     "Debounced save pruning must still enforce maximumDiskBytes (\(savedBytes) bytes across \(savedFiles.count) files)")
        print("PASS: BoxScoreCache debounced pruning enforces byte budget immediately upon crossing threshold")
    }

    @MainActor
    private static func verifyPhaseTwoLogoCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nba-p2-logos-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            FixtureProtocol.rawBodies = [:]
            FixtureProtocol.statuses = [:]
            FixtureProtocol.headers = [:]
            FixtureProtocol.resetCounts()
        }

        // Synthesize a valid 500x500 PNG in memory using CoreGraphics + LogoCache.encodePNG.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 500, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.33, green: 0.14, blue: 0.51, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
        let bigPNG = LogoCache.encodePNG(ctx.makeImage()!)!

        let clock = MutableClock(Date())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.resetCounts()
        FixtureProtocol.statuses = [:]
        FixtureProtocol.headers = [:]
        FixtureProtocol.rawBodies = ["cdn": bigPNG]

        let logoCache = LogoCache(
            directory: dir,
            session: URLSession(configuration: config),
            leaguePrefix: "nba",
            now: { clock.now }
        )
        let lalURL = Team(tricode: "LAL", score: 0, leaders: []).logoURL!

        // 1. Download, downsample <= 66px, synchronous L1 hit, and L2 disk persistence.
        precondition(logoCache.cachedImage(for: "LAL") == nil)
        let downloaded = await logoCache.image(for: "LAL", url: lalURL)
        precondition(downloaded != nil, "LogoCache must download and decode a valid PNG")
        let cg = downloaded!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(cg.width <= LogoCache.thumbnailMaxPixelSize && cg.height <= LogoCache.thumbnailMaxPixelSize,
                     "Downsampled logo must be <= 66px (got \(cg.width)x\(cg.height))")
        precondition(logoCache.cachedImage(for: "LAL") != nil, "L1 memory cache must serve synchronous hit after load")
        precondition(FixtureProtocol.count(for: "cdn") == 1)

        // 2. Evicting L1 reloads from L2 disk with 0 network calls.
        logoCache.clearMemoryCache()
        precondition(logoCache.cachedImage(for: "LAL") == nil)
        let reloaded = await logoCache.image(for: "LAL", url: lalURL)
        precondition(reloaded != nil && logoCache.cachedImage(for: "LAL") != nil)
        precondition(FixtureProtocol.count(for: "cdn") == 1, "L2 disk hit must not re-fetch from network")

        // 3. Invalid / path-traversal tricodes are rejected with 0 network requests or files.
        for bad in ["../escape", "lal", "LAL1", "A"] {
            let result = await logoCache.image(for: bad, url: lalURL)
            precondition(result == nil, "Invalid tricode \(bad) must be rejected")
        }
        precondition(FixtureProtocol.count(for: "cdn") == 1)

        // 4. Failure cooldown suppresses repeat downloads within 60s and retries after cooldown.
        FixtureProtocol.statuses["cdn"] = 500
        let bosURL = Team(tricode: "BOS", score: 0, leaders: []).logoURL!
        let fail1 = await logoCache.image(for: "BOS", url: bosURL)
        precondition(fail1 == nil && FixtureProtocol.count(for: "cdn") == 2)
        clock.advance(by: 30)
        let fail2 = await logoCache.image(for: "BOS", url: bosURL)
        precondition(fail2 == nil && FixtureProtocol.count(for: "cdn") == 2,
                     "Failed logo fetch must honor 60s cooldown")
        clock.advance(by: 31)
        FixtureProtocol.statuses = [:]
        let recovered = await logoCache.image(for: "BOS", url: bosURL)
        precondition(recovered != nil && FixtureProtocol.count(for: "cdn") == 3,
                     "Logo fetch must retry and succeed after cooldown expires")
        print("PASS: LogoCache downsamples to <=66px, serves synchronous L1 and offline L2 disk hits, blocks traversal, and honors failure cooldown")
    }

    @MainActor
    private static func verifyPhaseThreeLifecycleAndLanes() async throws {
        func waitUntil(_ message: String, _ condition: () async -> Bool) async throws {
            for _ in 0..<200 {
                if await condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure(message)
        }

        // 1. Hidden popover stays idle (0 requests on hide or resume while hidden); refreshes on open.
        let baseDate = ScoreDate.date(for: "2026-10-25")!.addingTimeInterval(10 * 3600) // 10:00 AM local
        let clock = MutableClock(baseDate)
        let hiddenClient = ScheduleNBA(emptyDate: "")
        let monitor = MockNetworkMonitor(isSatisfied: true)
        let hiddenService = NBAService(client: hiddenClient, now: { clock.now }, networkMonitor: monitor)
        hiddenService.setPopoverVisible(false)
        hiddenService.resume()
        try await Task.sleep(nanoseconds: 60_000_000)
        let idleRequests = await hiddenClient.requested.count
        precondition(idleRequests == 0, "Hidden popover must not poll or refresh on wake (got \(idleRequests))")
        hiddenService.setPopoverVisible(true)
        try await waitUntil("Opening popover must trigger immediate refresh") {
            await hiddenClient.requested.count >= 2
        }
        hiddenService.setPopoverVisible(false)
        print("PASS: hidden popover pauses polling completely and refreshes immediately on open")

        // 2. Decoupled lanes: a blocked future day (+2) never blocks Today or leaves Today loading.
        let laneDate = ScoreDate.date(for: "2026-10-25")!.addingTimeInterval(12 * 3600)
        let todayKey = ScoreDate.key(offset: 0, now: laneDate)
        let plusTwoKey = ScoreDate.key(offset: 2, now: laneDate)
        let laneClient = SelectiveGateNBA()
        await laneClient.block(date: plusTwoKey)
        let laneService = NBAService(client: laneClient, now: { laneDate }, networkMonitor: MockNetworkMonitor())
        laneService.selectDate(offset: 2)
        let futureFetch = Task { await laneService.refreshAll() }
        await laneClient.waitForBlocked(plusTwoKey)
        precondition(laneService.games[todayKey] != nil, "Today must publish even while +2 is blocked")
        precondition(laneService.isLoading, "Selected blocked +2 should report isLoading == true")
        laneService.selectDate(offset: 0)
        precondition(!laneService.isLoading, "Switching back to Today must not stay blocked on slow unselected +2")
        await laneService.refreshAll()
        precondition(laneService.games[todayKey]?.count == 1 && !laneService.isLoading)
        await laneClient.release(date: plusTwoKey)
        await futureFetch.value
        precondition(laneService.games[plusTwoKey]?.count == 1)
        print("PASS: decoupled lanes keep Today fast and responsive even while an unselected future day is slow")

        // 3. Settled Yesterday raises refresh TTL to 30 minutes once >3h past local midnight.
        let settledClock = MutableClock(ScoreDate.date(for: "2026-10-25")!.addingTimeInterval(4 * 3600)) // 4:00 AM local
        let yKey = ScoreDate.key(offset: -1, now: settledClock.now)
        let tKey = ScoreDate.key(offset: 0, now: settledClock.now)
        let settledClient = EnrichmentNBA()
        let yFinal = Game(id: "0022600801", status: .finished, statusText: "Final", broadcaster: "",
                          homeTeam: Team(tricode: "NYK", score: 110, leaders: []),
                          awayTeam: Team(tricode: "BOS", score: 100, leaders: []),
                          period: 4, gameTimeUTC: "2026-10-24T23:00:00Z")
        await settledClient.setGames([yFinal], for: yKey)
        await settledClient.setGames([], for: tKey)
        let yService = NBAService(client: settledClient, now: { settledClock.now }, networkMonitor: MockNetworkMonitor())
        await yService.refreshAll()
        let yInitialUpdate = yService.updatedAt[yKey]
        settledClock.advance(by: 6 * 60) // 6 min (> 5m old TTL, < 30m settled Yesterday TTL)
        await yService.refreshAll(force: false)
        precondition(yService.updatedAt[yKey] == yInitialUpdate,
                     "Settled unselected Yesterday must not refresh at 6 minutes")
        settledClock.advance(by: 25 * 60) // 31 min total (> 30m TTL)
        await yService.refreshAll(force: false)
        precondition(yService.updatedAt[yKey] != yInitialUpdate,
                     "Settled Yesterday should refresh after 30 minutes")
        print("PASS: settled unselected Yesterday raises its refresh TTL to 30 minutes")

        // 4. NWPathMonitor offline deferral and reconnect backoff reset.
        let netClock = MutableClock(ScoreDate.date(for: "2026-10-25")!.addingTimeInterval(14 * 3600))
        let netClient = ScheduleNBA(emptyDate: "")
        let netMonitor = MockNetworkMonitor(isSatisfied: false)
        let netService = NBAService(client: netClient, now: { netClock.now }, networkMonitor: netMonitor)
        netService.setPopoverVisible(true)
        netService.resume()
        try await Task.sleep(nanoseconds: 60_000_000)
        let offlineCount = await netClient.requested.count
        precondition(offlineCount == 0, "Visible wake/open while offline must defer automatic polling until satisfied")
        // Simulate a prior manual failure so backoff is active before reconnect.
        await netClient.fail(on: ScoreDate.key(now: netClock.now))
        await netService.refreshAll(force: true)
        precondition(netService.errors[ScoreDate.key(now: netClock.now)] != nil)
        await netClient.fail(on: nil)
        // Reconnect without advancing clock: backoff must reset and trigger immediate refresh.
        netMonitor.setSatisfied(true)
        try await waitUntil("Reconnect transition must clear backoff and refresh immediately") {
            netService.errors.isEmpty && netService.games[ScoreDate.key(now: netClock.now)] != nil
        }
        netService.setPopoverVisible(false)
        print("PASS: NWPathMonitor defers automatic polling while offline and resets backoff immediately on reconnect")
    }

    @MainActor
    private static func verifyPhaseFourCDNAndSnapshot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nba-p4-\(UUID().uuidString)")
        let originalTZ = NSTimeZone.default
        defer {
            NSTimeZone.default = originalTZ
            try? FileManager.default.removeItem(at: dir)
            FixtureProtocol.body = ""
            FixtureProtocol.bodies = [:]
            FixtureProtocol.rawBodies = [:]
            FixtureProtocol.statuses = [:]
            FixtureProtocol.headers = [:]
            FixtureProtocol.honorConditionalHeaders = false
            FixtureProtocol.resetCounts()
        }

        // 1. CDN conditional If-None-Match + If-Modified-Since -> 304 Not Modified reuses cached payload;
        //    stats.nba.com never receives conditional headers.
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let clock = MutableClock(ISO8601DateFormatter().date(from: "2026-10-26T22:00:00Z")!)
        let leagueDate = LeagueDate(containing: clock.now).key
        let localDate = ScoreDate.key(now: clock.now)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = NBAClient(session: URLSession(configuration: config), cache: BoxScoreCache(directory: dir.appendingPathComponent("box")), now: { clock.now })
        let cdnBody = """
        {"scoreboard": {"gameDate": "\(leagueDate)", "games": [
          {"gameId": "0022600901", "gameStatus": 2, "gameStatusText": "Q2", "period": 2,
           "gameTimeUTC": "2026-10-26T23:00:00Z",
           "homeTeam": {"teamTricode": "NYK", "score": 44}, "awayTeam": {"teamTricode": "BOS", "score": 41},
           "broadcasters": {"nationalTvBroadcasters": [{"broadcasterDisplay": "ESPN"}]}}]}}
        """
        FixtureProtocol.resetCounts()
        FixtureProtocol.honorConditionalHeaders = true
        FixtureProtocol.headers = [
            "ETag": "\"abc-123\"",
            "Last-Modified": "Mon, 26 Oct 2026 21:59:55 GMT"
        ]
        FixtureProtocol.body = scheduleBody(date: "", games: [])
        FixtureProtocol.bodies = ["cdn": cdnBody]

        let first = try await api.scoreboard(for: localDate)
        precondition(first.map(\.id) == ["0022600901"] && first[0].homeTeam.score == 44)
        let decodesAfter200 = await api.decodeCount
        // Corrupt the live body text so ONLY a 304 cached reuse can succeed on the second fetch!
        FixtureProtocol.bodies["cdn"] = "not-json"
        let second = try await api.scoreboard(for: localDate)
        precondition(second.map(\.id) == ["0022600901"] && second[0].homeTeam.score == 44,
                     "CDN 304 Not Modified must reuse the validated cached payload")
        let decodesAfter304 = await api.decodeCount
        precondition(decodesAfter304 == decodesAfter200,
                     "CDN 304 Not Modified must skip JSON decoding (before=\(decodesAfter200), after=\(decodesAfter304))")
        let (sentETag, sentMod) = FixtureProtocol.conditionalHeaders(for: "cdn")
        precondition(sentETag == "\"abc-123\"" && sentMod == "Mon, 26 Oct 2026 21:59:55 GMT")

        // Verify stats.nba.com never receives conditional headers.
        let futureStatsDate = "2026-10-29"
        FixtureProtocol.bodies[futureStatsDate] = scheduleBody(date: futureStatsDate, games: [("0022600902", "2026-10-29T23:00:00Z")])
        _ = try await api.scoreboard(for: futureStatsDate)
        _ = try await api.scoreboard(for: futureStatsDate)
        let (statsETag, statsMod) = FixtureProtocol.conditionalHeaders(for: futureStatsDate)
        precondition(statsETag == nil && statsMod == nil, "stats.nba.com must never use conditional cache headers")
        print("PASS: CDN requests send If-None-Match/If-Modified-Since and reuse cached payload on 304 while stats.nba.com stays unconditional")

        // 2. ScoreboardSnapshotCache: debounced save, cold-start hydration, expiry, league isolation, corruption rejection.
        let snapDir = dir.appendingPathComponent("snap")
        let snapClock = MutableClock(ScoreDate.date(for: "2026-10-26")!.addingTimeInterval(15 * 3600))
        let snapToday = ScoreDate.key(now: snapClock.now)
        let snapCache = ScoreboardSnapshotCache(
            directory: snapDir, league: "nba", debounceInterval: 0.05, now: { snapClock.now }
        )
        let snapClient = EnrichmentNBA()
        let snapGame = Game(id: "0022600910", status: .live, statusText: "Q3", broadcaster: "TNT",
                            homeTeam: Team(tricode: "LAL", score: 77, leaders: []),
                            awayTeam: Team(tricode: "GSW", score: 74, leaders: []),
                            period: 3, gameTimeUTC: "2026-10-26T23:00:00Z")
        await snapClient.setGames([snapGame], for: snapToday)
        let writerService = NBAService(
            client: snapClient,
            now: { snapClock.now },
            networkMonitor: MockNetworkMonitor(),
            snapshotCache: snapCache
        )
        await writerService.refreshAll()
        await snapCache.flush()

        // Hydrate a brand-new NBAService with an empty client: scores must be present on frame 0!
        let hydratedService = NBAService(
            client: ScheduleNBA(emptyDate: ""),
            now: { snapClock.now },
            networkMonitor: MockNetworkMonitor(),
            snapshotCache: snapCache
        )
        precondition(hydratedService.games[snapToday]?.first?.id == "0022600910"
                     && hydratedService.games[snapToday]?.first?.homeTeam.score == 77
                     && hydratedService.games[snapToday]?.first?.isLoadingLeaders == false
                     && hydratedService.updatedAt[snapToday] != nil,
                     "Cold-start NBAService must hydrate immediately from valid snapshot")

        // League isolation: WNBA reader ignores NBA snapshot.
        let wnbaCache = ScoreboardSnapshotCache(directory: snapDir, league: "wnba", now: { snapClock.now })
        precondition(wnbaCache.load(now: snapClock.now) == nil, "Snapshot must isolate nba vs wnba leagues")

        // Expiry: >6h old snapshot is rejected and deleted.
        precondition(snapCache.load(now: snapClock.now.addingTimeInterval(ScoreboardSnapshotCache.lifetime + 1)) == nil)
        let snapFile = snapDir.appendingPathComponent("snapshot-v1.json")
        precondition(!FileManager.default.fileExists(atPath: snapFile.path), "Expired snapshot file must be deleted")

        // Oversized (>512 KiB) and corrupted snapshot files are rejected and deleted.
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        try Data(repeating: 65, count: ScoreboardSnapshotCache.maximumBytes + 1).write(to: snapFile)
        precondition(snapCache.load(now: snapClock.now) == nil && !FileManager.default.fileExists(atPath: snapFile.path))
        try Data("{not valid json".utf8).write(to: snapFile)
        precondition(snapCache.load(now: snapClock.now) == nil && !FileManager.default.fileExists(atPath: snapFile.path))
        print("PASS: ScoreboardSnapshotCache hydrates cold starts, isolates leagues, expires after 6h, and deletes corrupt/oversized files")
    }

    @MainActor
    private static func verifyReviewFindingRegressions() async throws {
        func waitUntil(_ message: String, _ condition: () async -> Bool) async throws {
            for _ in 0..<200 {
                if await condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure(message)
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nba-review-fixes-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            FixtureProtocol.body = ""
            FixtureProtocol.bodies = [:]
            FixtureProtocol.rawBodies = [:]
            FixtureProtocol.statuses = [:]
            FixtureProtocol.headers = [:]
            FixtureProtocol.honorConditionalHeaders = false
            FixtureProtocol.configureGate(path: nil, release: nil)
            FixtureProtocol.resetCounts()
        }

        // 1. [P1] Snapshot hydration preserves progressByGame provenance so a lagging
        //    first refresh never regresses a hydrated Final/110 back to Live/90.
        let p1Date = "2026-10-27"
        let p1Clock = MutableClock(ScoreDate.date(for: p1Date)!.addingTimeInterval(15 * 3600))
        let p1SnapDir = dir.appendingPathComponent("p1-snap")
        let p1SnapCache = ScoreboardSnapshotCache(directory: p1SnapDir, league: "nba", debounceInterval: 0.05, now: { p1Clock.now })
        let p1WriterClient = EnrichmentNBA()
        let p1ID = "0022600950"
        let laggingLive = Game(id: p1ID, status: .live, statusText: "Q4 0:44", broadcaster: "",
                               homeTeam: Team(tricode: "NYK", score: 90, leaders: []),
                               awayTeam: Team(tricode: "BOS", score: 85, leaders: []),
                               period: 4, gameTimeUTC: "2026-10-27T23:00:00Z", gameClock: "PT00M44.00S")
        let finalProgress = GameProgress(status: .finished, statusText: "Final", period: 4,
                                         gameClock: "PT00M00.00S", homeScore: 110, awayScore: 100)
        let p1Player = CachedPlayer(id: "nba:7", name: "Closer", nameI: "Closer", position: "G",
                                    points: 30, rebounds: 5, assists: 5, steals: 1, blocks: 0,
                                    minutes: "PT35M00.00S", fgm: 10, fga: 18, threePm: 4, threePa: 8, ftm: 6, fta: 6)
        let p1Team = CachedTeamBoxScore(tricode: "NYK", players: [p1Player])
        await p1WriterClient.setGames([laggingLive], for: p1Date)
        await p1WriterClient.setBox(CachedBoxScore(gameId: p1ID, homeTeam: p1Team, awayTeam: p1Team,
                                                   homeScore: 110, awayScore: 100, progress: finalProgress,
                                                   cachedAt: p1Clock.now), for: p1ID)
        let p1Writer = NBAService(client: p1WriterClient, now: { p1Clock.now }, networkMonitor: MockNetworkMonitor(), snapshotCache: p1SnapCache)
        await p1Writer.refreshAll()
        try await waitUntil("Writer service should advance lagging game to Final via box score") {
            p1Writer.games[p1Date]?.first?.status == .finished && p1Writer.games[p1Date]?.first?.homeTeam.score == 110
        }
        await p1SnapCache.flush()

        // Restart into a new service whose first scoreboard refresh lags at Live/90.
        let p1RestartClient = EnrichmentNBA()
        await p1RestartClient.setGames([laggingLive], for: p1Date)
        let p1Restart = NBAService(client: p1RestartClient, now: { p1Clock.now }, networkMonitor: MockNetworkMonitor(), snapshotCache: p1SnapCache)
        precondition(p1Restart.games[p1Date]?.first?.status == .finished && p1Restart.games[p1Date]?.first?.homeTeam.score == 110)
        await p1Restart.refreshAll()
        precondition(p1Restart.games[p1Date]?.first?.status == .finished && p1Restart.games[p1Date]?.first?.homeTeam.score == 110,
                     "Lagging first refresh after snapshot hydration must never regress Final/110 to Live/90")
        // Official scoreboard final correction still wins once both feeds are final.
        let officialFinal = Game(id: p1ID, status: .finished, statusText: "Final", broadcaster: "",
                                 homeTeam: Team(tricode: "NYK", score: 112, leaders: []),
                                 awayTeam: Team(tricode: "BOS", score: 100, leaders: []),
                                 period: 4, gameTimeUTC: "2026-10-27T23:00:00Z", gameClock: "PT00M00.00S")
        await p1RestartClient.setGames([officialFinal], for: p1Date)
        await p1Restart.refreshAll()
        precondition(p1Restart.games[p1Date]?.first?.homeTeam.score == 112,
                     "Official final scoreboard total must win once scoreboard catches up")
        print("PASS: snapshot hydration preserves progress provenance and blocks backward score regression")

        // 2. [P2] Hiding popover or going offline during an in-flight refresh cancels
        //    owned tasks and blocks any follow-up scoreboard or enrichment requests.
        let hideDate = "2026-10-27"
        let hideClock = MutableClock(ScoreDate.date(for: hideDate)!.addingTimeInterval(15 * 3600))
        let hideMonitor = MockNetworkMonitor(isSatisfied: true)
        let hideClient = SelectiveGateNBA()
        await hideClient.block(date: hideDate)
        let hideService = NBAService(client: hideClient, now: { hideClock.now }, networkMonitor: hideMonitor)
        hideService.setPopoverVisible(true)
        await hideClient.waitForBlocked(hideDate)
        // Hide popover while foreground refresh is mid-flight, then trigger resume() while hidden.
        hideService.setPopoverVisible(false)
        hideService.resume()
        await hideClient.release(date: hideDate)
        try await Task.sleep(nanoseconds: 60_000_000)
        let hideRequests = await hideClient.requested.filter { $0 == hideDate }.count
        precondition(hideRequests == 1, "Hiding + resume() while hidden must not launch a follow-up batch (got \(hideRequests))")
        precondition(!hideService.isLoading && hideService.games[hideDate] == nil,
                     "Cancelled hidden refresh must not publish or spin")

        // Going offline during an in-flight refresh cancels it and updates isOnline for ContentView.
        let offClient = SelectiveGateNBA()
        await offClient.block(date: hideDate)
        let offMonitor = MockNetworkMonitor(isSatisfied: true)
        let offService = NBAService(client: offClient, now: { hideClock.now }, networkMonitor: offMonitor)
        offService.setPopoverVisible(true)
        await offClient.waitForBlocked(hideDate)
        offMonitor.setSatisfied(false)
        try await waitUntil("NBAService must publish isOnline=false so ContentView pauses TimelineView offline") { !offService.isOnline }
        await offClient.release(date: hideDate)
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(!offService.isLoading && offService.games[hideDate] == nil,
                     "Offline transition must cancel in-flight refreshes and launch zero follow-ups")
        offService.setPopoverVisible(false)
        print("PASS: hiding or going offline cancels in-flight refreshes, blocks enrichment/follow-ups, and exposes isOnline")

        // 3. [P2] A slow selected future day (+2) must never delay subsequent Today polling cycles.
        let pollClock = MutableClock(ScoreDate.date(for: "2026-10-27")!.addingTimeInterval(15 * 3600))
        let pollToday = ScoreDate.key(now: pollClock.now)
        let pollPlusTwo = ScoreDate.key(offset: 2, now: pollClock.now)
        let pollClient = SelectiveGateNBA()
        await pollClient.block(date: pollPlusTwo)
        let pollService = NBAService(
            client: pollClient,
            now: { pollClock.now },
            networkMonitor: MockNetworkMonitor(isSatisfied: true),
            sleep: { interval in
                pollClock.advance(by: interval + 1)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
        )
        pollService.setPopoverVisible(true)
        pollService.selectDate(offset: 2)
        await pollClient.waitForBlocked(pollPlusTwo)
        try await waitUntil("Today must complete multiple polling cycles while selected +2 remains blocked") {
            let todayCount = await pollClient.requested.filter { $0 == pollToday }.count
            return todayCount >= 3
        }
        pollService.setPopoverVisible(false)
        await pollClient.release(date: pollPlusTwo)
        print("PASS: slow selected future day never delays subsequent Today polling cycles")

        // 4. [P2] Concurrent eviction + 304 reinsertion must stay <= 24 entries and <= 8 MiB
        //    while skipping JSON decode on 304.
        let c304Clock = MutableClock(ISO8601DateFormatter().date(from: "2026-10-27T22:00:00Z")!)
        let c304Config = URLSessionConfiguration.ephemeral
        c304Config.protocolClasses = [FixtureProtocol.self]
        let c304BoxCache = BoxScoreCache(directory: dir.appendingPathComponent("c304-box"), now: { c304Clock.now })
        let c304API = NBAClient(session: URLSession(configuration: c304Config), cache: c304BoxCache, now: { c304Clock.now })
        FixtureProtocol.resetCounts()
        FixtureProtocol.honorConditionalHeaders = true
        FixtureProtocol.headers = [
            "ETag": "\"box-etag\"",
            "Last-Modified": "Tue, 27 Oct 2026 21:59:55 GMT"
        ]
        func makeBoxJSON(id: String) -> String {
            """
            {"game": {"gameId": "\(id)", "gameStatus": 2, "gameStatusText": "Q3", "period": 3, "gameClock": "PT05M00.00S",
              "homeTeam": {"teamTricode": "NYK", "score": 70, "players": [{"personId": 1, "name": "A", "statistics": {"points": 20}}]},
              "awayTeam": {"teamTricode": "BOS", "score": 68, "players": [{"personId": 2, "name": "B", "statistics": {"points": 18}}]}}}
            """
        }
        func makeLiveGame(id: String) -> Game {
            Game(id: id, status: .live, statusText: "Q3", broadcaster: "",
                 homeTeam: Team(tricode: "NYK", score: 70, leaders: []),
                 awayTeam: Team(tricode: "BOS", score: 68, leaders: []),
                 period: 3, gameTimeUTC: "2026-10-27T23:00:00Z")
        }
        for i in 1...25 {
            let gid = String(format: "00226010%02d", i)
            FixtureProtocol.bodies["boxscore_\(gid).json"] = makeBoxJSON(id: gid)
        }
        for i in 1...24 {
            let gid = String(format: "00226010%02d", i)
            c304Clock.advance(by: 1)
            _ = try await c304API.leaders(for: makeLiveGame(id: gid))
        }
        let initialCacheCount = await c304API.conditionalCacheCount
        precondition(initialCacheCount == NBAClient.maxConditionalEntries)
        let releaseSem = DispatchSemaphore(value: 0)
        FixtureProtocol.configureGate(path: "boxscore_0022601001.json", release: releaseSem)

        let decodesBefore = await c304API.decodeCount
        let revalTask = Task { try await c304API.leaders(for: makeLiveGame(id: "0022601001")) }
        try await waitUntil("304 revalidation request should reach FixtureProtocol gate") {
            FixtureProtocol.isGateEntered
        }
        // Evict 0022601001 by inserting entry #25 while 0022601001's 304 is paused mid-flight.
        c304Clock.advance(by: 1)
        _ = try await c304API.leaders(for: makeLiveGame(id: "0022601025"))
        releaseSem.signal()
        let revalidated = try await revalTask.value
        precondition(revalidated.gameId == "0022601001")
        let decodesAfter = await c304API.decodeCount
        // Only entry #25 decoded; 0022601001's 304 skipped JSON decode completely.
        precondition(decodesAfter == decodesBefore + 1, "304 revalidation must not decode JSON")
        let finalCount = await c304API.conditionalCacheCount
        let finalBytes = await c304API.conditionalCacheBytes
        precondition(finalCount <= NBAClient.maxConditionalEntries && finalBytes <= NBAClient.maxConditionalBytes,
                     "Concurrent eviction + 304 reinsertion exceeded conditional cache bounds (count=\(finalCount), bytes=\(finalBytes))")
        print("PASS: conditional 304 skips JSON decode and enforces 24-entry/8-MiB cap under concurrent eviction")

        // 5. [P2] settledAt preserves an aged BoxScoreCache entry's original cachedAt expiry.
        let ttlDate = "2026-10-27"
        let ttlClock = MutableClock(ScoreDate.date(for: ttlDate)!.addingTimeInterval(15 * 3600))
        let ttlClient = EnrichmentNBA()
        let ttlID = "0022600960"
        let ttlGame = Game(id: ttlID, status: .finished, statusText: "Final", broadcaster: "",
                           homeTeam: Team(tricode: "NYK", score: 108, leaders: []),
                           awayTeam: Team(tricode: "BOS", score: 102, leaders: []),
                           period: 4, gameTimeUTC: "2026-10-27T23:00:00Z", gameClock: "PT00M00.00S")
        let fiveHoursAgo = ttlClock.now.addingTimeInterval(-5 * 3600)
        let agedBox = CachedBoxScore(
            gameId: ttlID, homeTeam: p1Team, awayTeam: p1Team,
            homeScore: 108, awayScore: 102,
            progress: GameProgress(status: .finished, statusText: "Final", period: 4,
                                   gameClock: "PT00M00.00S", homeScore: 108, awayScore: 102),
            cachedAt: fiveHoursAgo
        )
        await ttlClient.setGames([ttlGame], for: ttlDate)
        await ttlClient.setBox(agedBox, for: ttlID)
        let ttlService = NBAService(client: ttlClient, now: { ttlClock.now }, networkMonitor: MockNetworkMonitor())
        await ttlService.refreshAll()
        try await waitUntil("Initial enrichment with 5h-old cached box should complete") {
            await ttlClient.leaderCalls == 1
        }
        // Still within remaining 1h of 6h TTL -> stays skipped.
        ttlClock.advance(by: 30 * 60)
        await ttlService.refreshAll()
        try await Task.sleep(nanoseconds: 40_000_000)
        let settledMidCalls = await ttlClient.leaderCalls
        precondition(settledMidCalls == 1, "5h-old box should remain settled 30m later")
        // Advance another 1.5h (total 7h since cachedAt > 6h lifetime) -> MUST re-enrich!
        ttlClock.advance(by: 90 * 60)
        await ttlService.refreshAll()
        try await waitUntil("5h-old box must expire after 2 more hours rather than getting a fresh 6h window") {
            await ttlClient.leaderCalls == 2
        }
        print("PASS: settled finals preserve original BoxScoreCache cachedAt expiry instead of extending TTL")

        // 6. [P2] ScoreboardSnapshotCache rejects unparseable gameTimeUTC ("not-a-date") and deletes the file.
        let badSnapDir = dir.appendingPathComponent("bad-snap")
        try FileManager.default.createDirectory(at: badSnapDir, withIntermediateDirectories: true)
        let badSnapCache = ScoreboardSnapshotCache(directory: badSnapDir, league: "nba", now: { p1Clock.now })
        let badGame = Game(id: "0022600970", status: .upcoming, statusText: "7:00 pm ET", broadcaster: "",
                           homeTeam: Team(tricode: "NYK", score: 0, leaders: []),
                           awayTeam: Team(tricode: "BOS", score: 0, leaders: []),
                           period: 0, gameTimeUTC: "not-a-date")
        let badSnap = ScoreboardSnapshotCache.Snapshot(
            league: "nba",
            savedAt: p1Clock.now,
            games: [p1Date: [badGame]],
            updatedAt: [p1Date: p1Clock.now]
        )
        let badFile = badSnapDir.appendingPathComponent("snapshot-v1.json")
        try JSONEncoder().encode(badSnap).write(to: badFile)
        precondition(badSnapCache.load(now: p1Clock.now) == nil && !FileManager.default.fileExists(atPath: badFile.path),
                     "Snapshot with unparseable gameTimeUTC must be rejected and deleted")
        print("PASS: ScoreboardSnapshotCache validates gameTimeUTC parsing and deletes malformed snapshots")

        // 7. Reopening popover near the end of a polling interval sleeps only the
        //    remaining freshness window instead of overshooting by a full interval.
        final class SleepRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [TimeInterval] = []
            func record(_ v: TimeInterval) { lock.lock(); values.append(v); lock.unlock() }
            var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let reopenDate = "2026-10-27"
        let reopenClock = MutableClock(ScoreDate.date(for: reopenDate)!.addingTimeInterval(15 * 3600))
        let reopenClient = EnrichmentNBA()
        let reopenID = "0022600981"
        let reopenLive = Game(id: reopenID, status: .live, statusText: "Q2 08:00", broadcaster: "",
                              homeTeam: Team(tricode: "NYK", score: 40, leaders: []),
                              awayTeam: Team(tricode: "BOS", score: 38, leaders: []),
                              period: 2, gameTimeUTC: "2026-10-27T23:00:00Z", gameClock: "PT08M00.00S")
        await reopenClient.setGames([reopenLive], for: reopenDate)
        await reopenClient.setBox(CachedBoxScore(gameId: reopenID, homeTeam: p1Team, awayTeam: p1Team,
                                                 homeScore: 40, awayScore: 38, cachedAt: reopenClock.now), for: reopenID)
        let sleeps = SleepRecorder()
        let reopenService = NBAService(
            client: reopenClient,
            now: { reopenClock.now },
            networkMonitor: MockNetworkMonitor(),
            sleep: { interval in
                sleeps.record(interval)
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        )
        reopenService.setPopoverVisible(true)
        try await waitUntil("Initial open should fetch live game and enter first 15s sleep") {
            sleeps.all.count >= 1
        }
        precondition(abs(sleeps.all[0] - 15) < 0.5, "Initial live sleep should be ~15s (got \(sleeps.all[0]))")
        reopenService.setPopoverVisible(false)
        // Reopen 13s later (< 15s live interval): should sleep only ~2s, not another 15s.
        reopenClock.advance(by: 13)
        reopenService.setPopoverVisible(true)
        try await waitUntil("Reopen within freshness window should schedule remaining ~2s sleep") {
            sleeps.all.count >= 2
        }
        precondition(sleeps.all[1] >= 1 && sleeps.all[1] <= 2.5,
                     "Reopen sleep must be remaining ~2s, not full 15s (got \(sleeps.all[1]))")
        reopenService.setPopoverVisible(false)
        print("PASS: popover reopen sleeps only the remaining freshness window instead of overshooting")

        // 8. Hiding mid-enrichment cancels leader tasks; quick reopen (<15s) resumes
        //    those cancelled box-score/leader fetches immediately without re-fetching scoreboard.
        let resumeDate = "2026-10-27"
        let resumeClock = MutableClock(ScoreDate.date(for: resumeDate)!.addingTimeInterval(15 * 3600))
        let resumeClient = EnrichmentNBA()
        let resumeID = "0022600982"
        let resumeLive = Game(id: resumeID, status: .live, statusText: "Q3 04:00", broadcaster: "",
                              homeTeam: Team(tricode: "NYK", score: 70, leaders: []),
                              awayTeam: Team(tricode: "BOS", score: 68, leaders: []),
                              period: 3, gameTimeUTC: "2026-10-27T23:00:00Z", gameClock: "PT04M00.00S")
        let aheadBox = CachedBoxScore(
            gameId: resumeID, homeTeam: p1Team, awayTeam: p1Team,
            homeScore: 74, awayScore: 68,
            progress: GameProgress(status: .live, statusText: "Q3 03:30", period: 3,
                                   gameClock: "PT03M30.00S", homeScore: 74, awayScore: 68),
            cachedAt: resumeClock.now
        )
        await resumeClient.setGames([resumeLive], for: resumeDate)
        await resumeClient.setBox(aheadBox, for: resumeID)
        await resumeClient.block(gameId: resumeID)
        let resumeService = NBAService(
            client: resumeClient,
            now: { resumeClock.now },
            networkMonitor: MockNetworkMonitor(),
            sleep: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) }
        )
        resumeService.setPopoverVisible(true)
        await resumeClient.waitForLeaderFetch()
        let scoreboardBeforeHide = await resumeClient.scoreboardCalls
        resumeService.setPopoverVisible(false)
        await resumeClient.releaseLeaderFetch()
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(resumeService.games[resumeDate]?.first?.homeTeam.leaders.isEmpty == true,
                     "Cancelled leader fetch must not apply while hidden")
        // Reopen 3s later (still within 15s freshness window): interrupted enrichment resumes immediately!
        resumeClock.advance(by: 3)
        resumeService.setPopoverVisible(true)
        try await waitUntil("Interrupted leader/box-score enrichment must resume immediately on reopen") {
            let g = resumeService.games[resumeDate]?.first
            return g?.homeTeam.leaders.first?.points == 30 && g?.homeTeam.score == 74
        }
        let scoreboardAfterReopen = await resumeClient.scoreboardCalls
        precondition(scoreboardAfterReopen == scoreboardBeforeHide,
                     "Resuming interrupted enrichment within freshness window must not duplicate scoreboard fetch")
        resumeService.setPopoverVisible(false)
        print("PASS: cancelled leader/box-score enrichment resumes immediately on quick popover reopen")

        // 9. Stale concurrent 304 Not Modified must not overwrite a newer ETag in conditionalCache.
        let etagClock = MutableClock(ISO8601DateFormatter().date(from: "2026-10-27T22:10:00Z")!)
        let etagConfig = URLSessionConfiguration.ephemeral
        etagConfig.protocolClasses = [FixtureProtocol.self]
        let etagAPI = NBAClient(
            session: URLSession(configuration: etagConfig),
            cache: BoxScoreCache(directory: dir.appendingPathComponent("etag-box"), now: { etagClock.now }),
            now: { etagClock.now }
        )
        let etagGID = "0022601099"
        let etagPath = "boxscore_\(etagGID).json"
        func makeScoredBoxJSON(score: Int) -> String {
            """
            {"game": {"gameId": "\(etagGID)", "gameStatus": 2, "gameStatusText": "Q3", "period": 3, "gameClock": "PT05M00.00S",
              "homeTeam": {"teamTricode": "NYK", "score": \(score), "players": [{"personId": 1, "name": "A", "statistics": {"points": 20}}]},
              "awayTeam": {"teamTricode": "BOS", "score": 68, "players": [{"personId": 2, "name": "B", "statistics": {"points": 18}}]}}}
            """
        }
        FixtureProtocol.resetCounts()
        FixtureProtocol.honorConditionalHeaders = true
        FixtureProtocol.headers = ["ETag": "\"v1\"", "Last-Modified": "Tue, 27 Oct 2026 22:00:00 GMT"]
        FixtureProtocol.bodies[etagPath] = makeScoredBoxJSON(score: 70)
        let etagGame = makeLiveGame(id: etagGID)
        let v1Box = try await etagAPI.leaders(for: etagGame)
        precondition(v1Box.homeScore == 70)

        let staleRelease = DispatchSemaphore(value: 0)
        FixtureProtocol.configureGate(path: etagPath, release: staleRelease)
        let stale304Task = Task { try await etagAPI.leaders(for: etagGame) }
        try await waitUntil("Stale 304 request should enter FixtureProtocol gate with ETag v1") {
            FixtureProtocol.isGateEntered
        }
        // Clear gate and update server to v2 (score 82) while stale 304 is paused.
        FixtureProtocol.configureGate(path: nil, release: nil)
        FixtureProtocol.headers = ["ETag": "\"v2\"", "Last-Modified": "Tue, 27 Oct 2026 22:05:00 GMT"]
        FixtureProtocol.bodies[etagPath] = makeScoredBoxJSON(score: 82)
        let v2Box = try await etagAPI.leaders(for: etagGame)
        precondition(v2Box.homeScore == 82)

        // Release stale 304 (carrying ETag v1): must return newer v2 and preserve ETag v2 in cache.
        staleRelease.signal()
        let staleResult = try await stale304Task.value
        precondition(staleResult.homeScore == 82, "Stale concurrent 304 must return newer cached response (got \(String(describing: staleResult.homeScore)))")
        FixtureProtocol.resetCounts()
        let followUpBox = try await etagAPI.leaders(for: etagGame)
        precondition(followUpBox.homeScore == 82)
        precondition(FixtureProtocol.conditionalHeaders(for: "cdn").etag == "\"v2\"",
                     "Stale concurrent 304 must never downgrade conditionalCache ETag back to v1")
        print("PASS: concurrent 304 never overwrites a newer ETag or downgrades cached response")
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
        let clock = MutableClock(ISO8601DateFormatter().date(from: "2026-10-07T23:30:00Z")!)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = NBAClient(session: URLSession(configuration: config), now: { clock.now })
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

        let service = NBAService(client: api, now: { clock.now }, networkMonitor: MockNetworkMonitor())
        await service.refreshAll()
        precondition(service.errors.isEmpty && service.games["2026-10-08"]?.map(\.id) == ["29", "33"])
        service.selectDate(offset: 2)
        await service.refreshAll()
        service.selectDate(offset: 3)
        await service.refreshAll()
        precondition(service.games["2026-10-10"]?.isEmpty == true && service.games["2026-10-11"]?.map(\.id) == ["43"])
        let retainedUpdate = service.updatedAt["2026-10-08"]
        service.selectDate(offset: 1)
        FixtureProtocol.statuses["2026-10-08"] = 503
        await service.refreshAll()
        precondition(Set(service.errors.keys) == ["2026-10-08", "2026-10-09"])
        precondition(service.games["2026-10-08"]?.map(\.id) == ["29", "33"] && service.updatedAt["2026-10-08"] == retainedUpdate)
        FixtureProtocol.statuses = [:]
        await service.refreshAll()
        precondition(service.errors.isEmpty)
        service.selectDate(offset: 0)
        print("PASS: an overlapping schedule failure retains local-day scores and recovers independently")

        clock.now = ISO8601DateFormatter().date(from: "2026-10-08T23:30:00Z")!
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

        // At 9:30 PM Pacific (12:30 AM Eastern the next day), Today must remain
        // anchored to the Pacific system date and continue using the live CDN
        // scoreboard for that night's Eastern slate.
        clock.now = ISO8601DateFormatter().date(from: "2026-10-08T04:30:00Z")!
        FixtureProtocol.bodies = [
            "cdn": scheduleBody(date: "2026-10-07", games: [("50", "2026-10-08T06:59:59.999Z")]),
            "2026-10-08": scheduleBody(date: "2026-10-08", games: [])
        ]
        FixtureProtocol.statuses = ["2026-10-07": 503]
        service.setPopoverVisible(true)
        precondition(service.day == "2026-10-07" && service.upcomingDates == ["2026-10-08", "2026-10-09", "2026-10-10"])
        await service.refreshAll()
        precondition(service.day == "2026-10-07" && service.games["2026-10-07"]?.map(\.id) == ["50"])
        FixtureProtocol.statuses = [:]
        print("PASS: after 9 PM Pacific (Eastern midnight), Today stays on the system date and keeps using the live CDN scoreboard")

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
