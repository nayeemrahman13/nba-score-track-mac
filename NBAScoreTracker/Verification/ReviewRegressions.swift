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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
private struct ReviewRegressions {
    @MainActor
    static func main() async throws {
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
    }
}
