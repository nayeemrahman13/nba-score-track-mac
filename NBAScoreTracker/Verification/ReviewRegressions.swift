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
                if gates.count == 3 { started?.resume(); started = nil }
            }
        }
        return []
    }
    func leaders(for game: Game) async throws -> CachedBoxScore { throw NBAError.invalidResponse }
    func waitForFirstBatch() async {
        if gates.count == 3 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        blocked = false
        gates.forEach { $0.resume() }
        gates.removeAll()
    }
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
            precondition(dates.count == 6, "Lifecycle event was lost or refreshes duplicated")
            precondition(Set(dates.suffix(3)) == Set([-1, 0, 1].map { ScoreDate.key(offset: $0, now: clock) }))
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
        precondition(dates.count == 3, "Ordinary joined refresh bypassed freshness")
        print("PASS: ordinary concurrent refreshes still coalesce")

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
