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

        // Audit Medium #1: one malformed game row must drop only itself. Per-row
        // problems are data; structural problems (rows present, zero valid) throw.
        let cdnRows = [
            CDNGame(gameId: "0022600002", gameStatus: 2, gameStatusText: "Q4", period: 4, gameTimeUTC: nil,
                    homeTeam: CDNTeam(teamTricode: "NYK", score: 100), awayTeam: CDNTeam(teamTricode: "BOS", score: 90),
                    broadcasters: CDNBroadcasters(nationalTvBroadcasters: [CDNBroadcaster(broadcasterDisplay: "TNT")],
                                                  nationalRadioBroadcasters: nil, homeTvBroadcasters: nil, awayTvBroadcasters: nil)),
            CDNGame(gameId: "0022600003", gameStatus: 1, gameStatusText: "7:00 pm ET", period: 0, gameTimeUTC: nil,
                    homeTeam: CDNTeam(teamTricode: "LAL", score: nil), awayTeam: CDNTeam(teamTricode: "GSW", score: nil),
                    broadcasters: nil)
        ]
        let decodedCDN = try NBAClient.decodeGames(cdnRows)
        precondition(decodedCDN.map(\.id) == ["0022600002", "0022600003"], "All-valid rows must decode unchanged")
        precondition(decodedCDN[0].status == .live && decodedCDN[0].homeTeam.tricode == "NYK" && decodedCDN[0].broadcaster == "TNT")
        precondition(decodedCDN[1].status == .upcoming)
        let apiRows = [
            APIGame(gameId: "0022600004", gameStatus: 3, gameStatusText: "Final", period: 4, gameTimeUTC: nil,
                    homeTeam: APITeam(teamTricode: "MIA", score: 112), awayTeam: APITeam(teamTricode: "BOS", score: 108),
                    broadcasters: Broadcasters(nationalBroadcasters: [Broadcaster(broadcastDisplay: "ABC")], nationalOttBroadcasters: nil)),
            APIGame(gameId: "0022600005", gameStatus: 1, gameStatusText: "7:30 pm ET", period: 0, gameTimeUTC: nil,
                    homeTeam: APITeam(teamTricode: "DAL", score: nil), awayTeam: APITeam(teamTricode: "PHX", score: nil),
                    broadcasters: nil)
        ]
        let decodedAPI = try NBAClient.decodeGames(apiRows)
        precondition(decodedAPI.map(\.id) == ["0022600004", "0022600005"], "Stats-feed rows must decode through the same helper")
        precondition(decodedAPI[0].status == .finished && decodedAPI[0].broadcaster == "ABC")
        print("PASS: all-valid rows decode unchanged on both the CDN and stats shapes")

        // The audit's realistic trigger: a game that just flipped live and is
        // published momentarily with null scores.
        let liveFlip = CDNGame(gameId: "0022600006", gameStatus: 2, gameStatusText: "Q1", period: 1, gameTimeUTC: nil,
                               homeTeam: CDNTeam(teamTricode: "CLE", score: nil), awayTeam: CDNTeam(teamTricode: "DET", score: nil),
                               broadcasters: nil)
        let badStatus = CDNGame(gameId: "0022600007", gameStatus: 9, gameStatusText: "??", period: 0, gameTimeUTC: nil,
                                homeTeam: CDNTeam(teamTricode: "SAS", score: nil), awayTeam: CDNTeam(teamTricode: "MEM", score: nil),
                                broadcasters: nil)
        let surviving = try NBAClient.decodeGames([cdnRows[0], liveFlip, badStatus, cdnRows[1]])
        precondition(surviving.map(\.id) == ["0022600002", "0022600003"], "A malformed row must drop only itself")
        print("PASS: malformed game rows are skipped and logged while their siblings survive")

        let allMalformed = [
            APIGame(gameId: "0022600008", gameStatus: 9, gameStatusText: "?", period: 0, gameTimeUTC: nil,
                    homeTeam: APITeam(teamTricode: "OKC", score: nil), awayTeam: APITeam(teamTricode: "UTA", score: nil), broadcasters: nil),
            APIGame(gameId: "0022600009", gameStatus: 2, gameStatusText: "Q2", period: 2, gameTimeUTC: nil,
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
    }
}
