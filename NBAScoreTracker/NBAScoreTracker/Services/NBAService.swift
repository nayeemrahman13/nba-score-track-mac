import Foundation
import Combine
import os

@MainActor
class NBAService: ObservableObject {
    @Published var games: [String: [Game]] = [:]
    @Published var isLoading = false
    @Published var hasLiveGames = false
    
    private var cancellables = Set<AnyCancellable>()
    private var pollingTimer: Timer?
    private var isPopoverVisible = false
    private var lastRefreshAt: Date?
    private var gameOrderByDate: [String: [String]] = [:]
    
    private let logger = Logger(subsystem: "NBAScoreTracker", category: "NBAService")
    
    // Custom URLSession with proper configuration
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    
    // NBA API requires specific headers to avoid blocking
    private var headers: [String: String] {
        [
            "Host": "stats.nba.com",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate, br",
            "Origin": "https://www.nba.com",
            "Referer": "https://www.nba.com/",
            "Connection": "keep-alive",
            "x-nba-stats-origin": "stats",
            "x-nba-stats-token": "true"
        ]
    }
    
    // MARK: - Public API
    
    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        updatePollingInterval()
        if visible {
            Task { await refreshAll() }
        }
    }
    
    func refreshAll() async {
        let today = formattedDate(offset: 0)
        let yesterday = formattedDate(offset: -1)
        let tomorrow = formattedDate(offset: 1)
        
        await fetchGames(for: [today, yesterday, tomorrow])
    }
    
    private func refreshAllIfStale(minInterval: TimeInterval) async {
        if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < minInterval {
            return
        }
        await refreshAll()
    }
    
    // MARK: - Polling
    
    private func updatePollingInterval() {
        pollingTimer?.invalidate()
        
        let interval: TimeInterval
        if isPopoverVisible && hasLiveGames {
            interval = 15
        } else if isPopoverVisible {
            interval = 900
        } else if hasLiveGames {
            interval = 300
        } else {
            interval = 3600
        }
        
        guard interval > 0 else { return }
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAllIfStale(minInterval: interval)
            }
        }
    }
    
    // MARK: - Fetching
    
    private func fetchGames(for dates: [String]) async {
        isLoading = true
        defer { isLoading = false }
        
        // Fetch dates sequentially to avoid overwhelming the API
        var updatedGames = games
        for date in dates {
            let fetchedGames = await fetchSingleDate(date)
            let stabilized = applyStableOrder(for: date, games: fetchedGames)
            updatedGames[date] = stabilized
            games = updatedGames
            scheduleLeaderFetches(for: stabilized, date: date)
        }
        
        lastRefreshAt = Date()
        
        hasLiveGames = games.values.flatMap { $0 }.contains { $0.status == .live }
        updatePollingInterval()
    }
    
    private func fetchSingleDate(_ date: String) async -> [Game] {
        let today = formattedDate(offset: 0)
        
        // For today's games, prefer CDN (more real-time)
        if date == today {
            let cdnGames = await fetchFromCDN()
            if !cdnGames.isEmpty {
                return cdnGames
            }
        }
        
        // For other dates (and as fallback), use stats.nba.com
        if let games = await fetchFromStatsAPI(date: date), !games.isEmpty {
            return games
        }
        
        // Final fallback to CDN for today's games
        if date == today {
            return await fetchFromCDN()
        }
        
        return []
    }
    
    private func fetchFromStatsAPI(date: String) async -> [Game]? {
        guard let url = URL(string: "https://stats.nba.com/stats/scoreboardv3?GameDate=\(date)&LeagueID=00") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        applyHeaders(to: &request)
        
        do {
            let (data, response) = try await fetchWithRetry(request: request, maxRetries: 3)
            
            if let httpResponse = response as? HTTPURLResponse {
                logger.debug("NBA API status \(httpResponse.statusCode) for \(date, privacy: .public)")
                if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
                    logger.warning("NBA API blocked (status \(httpResponse.statusCode)) for \(date, privacy: .public)")
                    return nil
                }
            }
            
            // Try parsing as stats.nba.com format
            struct StatsResponse: Codable {
                let scoreboard: StatsScoreboard
            }
            struct StatsScoreboard: Codable {
                let games: [StatsGame]
            }
            struct StatsGame: Codable {
                let gameId: String
                let gameStatus: Int
                let gameStatusText: String
                let period: Int
                let gameTimeUTC: String?
                let homeTeam: StatsTeam
                let awayTeam: StatsTeam
                let broadcasters: Broadcasters?
            }
            struct StatsTeam: Codable {
                let teamTricode: String?
                let score: Int?
            }
            
            let statsResponse = try JSONDecoder().decode(StatsResponse.self, from: data)
            
            var formattedGames: [Game] = []
            
            for statsGame in statsResponse.scoreboard.games {
                var homeTeam = Team(
                    tricode: statsGame.homeTeam.teamTricode ?? "TBD",
                    score: statsGame.homeTeam.score ?? 0,
                    leaders: []
                )
                var awayTeam = Team(
                    tricode: statsGame.awayTeam.teamTricode ?? "TBD",
                    score: statsGame.awayTeam.score ?? 0,
                    leaders: []
                )
                
                let game = Game(
                    id: statsGame.gameId,
                    status: Game.GameStatus(rawValue: statsGame.gameStatus) ?? .upcoming,
                    statusText: statsGame.gameStatusText,
                    broadcaster: getPrimaryBroadcaster(statsGame.broadcasters),
                    homeTeam: homeTeam,
                    awayTeam: awayTeam,
                    period: statsGame.period,
                    gameTimeUTC: statsGame.gameTimeUTC ?? ""
                )
                
                formattedGames.append(game)
            }
            
            return formattedGames
        } catch {
            logger.error("Stats API error for \(date, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    private func fetchFromCDN() async -> [Game] {
        guard let url = URL(string: "https://cdn.nba.com/static/json/liveData/scoreboard/todaysScoreboard_00.json") else {
            return []
        }
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await fetchWithRetry(request: request)
            if let httpResponse = response as? HTTPURLResponse {
                logger.debug("CDN status \(httpResponse.statusCode)")
            }
            let scoreboardResponse = try JSONDecoder().decode(CDNScoreboardResponse.self, from: data)
            
            var formattedGames: [Game] = []
            
            for cdnGame in scoreboardResponse.scoreboard.games {
                var homeTeam = Team(
                    tricode: cdnGame.homeTeam.teamTricode ?? "TBD",
                    score: cdnGame.homeTeam.score ?? 0,
                    leaders: []
                )
                var awayTeam = Team(
                    tricode: cdnGame.awayTeam.teamTricode ?? "TBD",
                    score: cdnGame.awayTeam.score ?? 0,
                    leaders: []
                )
                
                let game = Game(
                    id: cdnGame.gameId,
                    status: Game.GameStatus(rawValue: cdnGame.gameStatus) ?? .upcoming,
                    statusText: cdnGame.gameStatusText,
                    broadcaster: getCDNBroadcaster(cdnGame.broadcasters),
                    homeTeam: homeTeam,
                    awayTeam: awayTeam,
                    period: cdnGame.period,
                    gameTimeUTC: cdnGame.gameTimeUTC ?? ""
                )
                
                formattedGames.append(game)
            }
            
            return formattedGames
        } catch {
            logger.error("CDN error: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
    
    private func getCDNBroadcaster(_ broadcasters: CDNBroadcasters?) -> String {
        guard let broadcasters = broadcasters else { return "League Pass" }
        
        if let national = broadcasters.nationalTvBroadcasters?.first?.broadcasterDisplay {
            if national.uppercased().contains("AMAZON") { return "Prime Video" }
            if national.uppercased().contains("PEACOCK") { return "Peacock" }
            return national
        }
        
        return "League Pass"
    }
    
    private func fetchGameLeaders(gameId: String, isFinished: Bool) async -> (home: [Player], away: [Player], homeScore: Int?, awayScore: Int?)? {
        // Check cache first for finished games
        if isFinished {
            if let cached = await BoxScoreCache.shared.get(gameId: gameId) {
                return (
                    cached.homeTeam.players.prefix(3).map { $0.toPlayer() },
                    cached.awayTeam.players.prefix(3).map { $0.toPlayer() },
                    nil,
                    nil
                )
            }
        }
        
        guard let url = URL(string: "https://cdn.nba.com/static/json/liveData/boxscore/boxscore_\(gameId).json") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await fetchWithRetry(request: request, maxRetries: 2)
            let boxscoreResponse = try JSONDecoder().decode(BoxscoreResponse.self, from: data)
            
            guard let gameBox = boxscoreResponse.game else { return nil }
            
            // Build cached box score with full player data
            let cachedBoxScore = CachedBoxScore(
                gameId: gameId,
                homeTeam: buildCachedTeamBoxScore(
                    tricode: gameBox.homeTeam?.teamTricode ?? "TBD",
                    players: gameBox.homeTeam?.players
                ),
                awayTeam: buildCachedTeamBoxScore(
                    tricode: gameBox.awayTeam?.teamTricode ?? "TBD",
                    players: gameBox.awayTeam?.players
                )
            )
            
            // Save to cache
            await BoxScoreCache.shared.save(gameId: gameId, boxScore: cachedBoxScore, isFinished: isFinished)
            
            let homeLeaders = getTeamLeaders(gameBox.homeTeam?.players)
            let awayLeaders = getTeamLeaders(gameBox.awayTeam?.players)
            
            return (
                homeLeaders,
                awayLeaders,
                gameBox.homeTeam?.score,
                gameBox.awayTeam?.score
            )
        } catch {
            logger.debug("Boxscore error for \(gameId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    private func scheduleLeaderFetches(for games: [Game], date: String) {
        let candidates = games.filter { game in
            (game.status == .live || game.status == .finished) &&
            game.homeTeam.leaders.isEmpty && game.awayTeam.leaders.isEmpty
        }
        
        guard !candidates.isEmpty else { return }
        
        Task { [weak self] in
            guard let self else { return }
            
            for game in candidates {
                let isFinished = game.status == .finished
                if let leaders = await self.fetchGameLeaders(gameId: game.id, isFinished: isFinished) {
                    await self.updateGameLeaders(
                        gameId: game.id,
                        date: date,
                        home: leaders.home,
                        away: leaders.away,
                        homeScore: leaders.homeScore,
                        awayScore: leaders.awayScore
                    )
                }
                
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    
    private func updateGameLeaders(
        gameId: String,
        date: String,
        home: [Player],
        away: [Player],
        homeScore: Int?,
        awayScore: Int?
    ) {
        var updatedGames = games
        guard var dayGames = updatedGames[date],
              let index = dayGames.firstIndex(where: { $0.id == gameId }) else {
            return
        }
        
        let game = dayGames[index]
        var homeTeam = game.homeTeam
        var awayTeam = game.awayTeam
        homeTeam.leaders = home
        awayTeam.leaders = away
        if let homeScore { homeTeam = Team(tricode: homeTeam.tricode, score: homeScore, leaders: homeTeam.leaders) }
        if let awayScore { awayTeam = Team(tricode: awayTeam.tricode, score: awayScore, leaders: awayTeam.leaders) }
        
        dayGames[index] = Game(
            id: game.id,
            status: game.status,
            statusText: game.statusText,
            broadcaster: game.broadcaster,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            period: game.period,
            gameTimeUTC: game.gameTimeUTC
        )
        
        updatedGames[date] = dayGames
        games = updatedGames
    }
    
    private func applyStableOrder(for date: String, games: [Game]) -> [Game] {
        let existingOrder = gameOrderByDate[date] ?? []
        let indexById = Dictionary(uniqueKeysWithValues: existingOrder.enumerated().map { ($0.element, $0.offset) })
        
        let sorted = games.sorted { lhs, rhs in
            let lIndex = indexById[lhs.id]
            let rIndex = indexById[rhs.id]
            
            switch (lIndex, rIndex) {
            case let (l?, r?):
                return l < r
            case (nil, nil):
                if lhs.gameTimeUTC != rhs.gameTimeUTC {
                    return lhs.gameTimeUTC < rhs.gameTimeUTC
                }
                return lhs.id < rhs.id
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        }
        
        gameOrderByDate[date] = sorted.map { $0.id }
        return sorted
    }
    
    private func buildCachedTeamBoxScore(tricode: String, players: [BoxscorePlayer]?) -> CachedTeamBoxScore {
        let cachedPlayers = (players ?? [])
            .filter { ($0.statistics?.points ?? 0) > 0 || ($0.statistics?.minutes ?? "").count > 0 }
            .sorted { ($0.statistics?.points ?? 0) > ($1.statistics?.points ?? 0) }
            .map { p -> CachedPlayer in
                CachedPlayer(
                    name: p.name ?? "Unknown",
                    nameI: p.nameI ?? "",
                    position: p.position ?? "",
                    points: p.statistics?.points ?? 0,
                    rebounds: p.statistics?.reboundsTotal ?? 0,
                    assists: p.statistics?.assists ?? 0,
                    steals: p.statistics?.steals ?? 0,
                    blocks: p.statistics?.blocks ?? 0,
                    minutes: p.statistics?.minutes ?? "0",
                    fgm: p.statistics?.fieldGoalsMade ?? 0,
                    fga: p.statistics?.fieldGoalsAttempted ?? 0,
                    threePm: p.statistics?.threePointersMade ?? 0,
                    threePa: p.statistics?.threePointersAttempted ?? 0,
                    ftm: p.statistics?.freeThrowsMade ?? 0,
                    fta: p.statistics?.freeThrowsAttempted ?? 0
                )
            }
        
        return CachedTeamBoxScore(tricode: tricode, players: cachedPlayers)
    }
    
    // MARK: - Retry Logic
    
    private func fetchWithRetry(request: URLRequest, maxRetries: Int = 3) async throws -> (Data, URLResponse) {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                return try await session.data(for: request)
            } catch {
                lastError = error
                
                // Don't retry on certain errors
                if (error as NSError).code == NSURLErrorCancelled {
                    throw error
                }
                
                if (error as NSError).code == NSURLErrorNotConnectedToInternet {
                    logger.warning("No internet connection, backing off")
                }
                
                // Exponential backoff: 200ms, 400ms, 800ms...
                let delay = UInt64(200_000_000 * (1 << attempt))
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        
        throw lastError ?? URLError(.unknown)
    }
    
    private func applyHeaders(to request: inout URLRequest) {
        headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
    
    // MARK: - Helpers
    
    private func getTeamLeaders(_ players: [BoxscorePlayer]?) -> [Player] {
        guard let players, !players.isEmpty else { return [] }
        
        struct Candidate {
            let player: BoxscorePlayer
            let points: Int
            let rebounds: Int
            let assists: Int
            let name: String
            let nameKey: String
        }
        
        func nameKey(for name: String) -> String {
            let parts = name.lowercased().split(separator: " ")
            if let last = parts.last {
                let first = parts.first ?? ""
                return "\(last),\(first)"
            }
            return name.lowercased()
        }
        
        let candidates: [Candidate] = players.map { p in
            let name = p.name ?? "Unknown"
            return Candidate(
                player: p,
                points: p.statistics?.points ?? 0,
                rebounds: p.statistics?.reboundsTotal ?? 0,
                assists: p.statistics?.assists ?? 0,
                name: name,
                nameKey: nameKey(for: name)
            )
        }
        
        let hasStats = candidates.contains { $0.points > 0 || $0.rebounds > 0 || $0.assists > 0 }
        let withStats = candidates.filter { $0.points > 0 || $0.rebounds > 0 || $0.assists > 0 }
        let withoutStats = candidates.filter { $0.points == 0 && $0.rebounds == 0 && $0.assists == 0 }
        
        let sortedWithStats = withStats.sorted { lhs, rhs in
            if lhs.points != rhs.points { return lhs.points > rhs.points }
            if lhs.rebounds != rhs.rebounds { return lhs.rebounds > rhs.rebounds }
            if lhs.assists != rhs.assists { return lhs.assists > rhs.assists }
            return lhs.nameKey < rhs.nameKey
        }
        
        let sortedWithoutStats = withoutStats.sorted { $0.nameKey < $1.nameKey }
        
        var leaders: [Candidate] = []
        if hasStats {
            leaders.append(contentsOf: sortedWithStats.prefix(3))
            if leaders.count < 3 {
                leaders.append(contentsOf: sortedWithoutStats.prefix(3 - leaders.count))
            }
        } else {
            leaders = sortedWithoutStats.prefix(3).map { $0 }
        }
        
        return leaders.map { c in
            Player(
                name: c.player.name ?? "Unknown",
                nameI: c.player.nameI ?? (c.player.name.map { "\($0.first ?? "?"). \($0.split(separator: " ").last ?? "")" } ?? "Player"),
                position: c.player.position ?? "",
                points: c.points,
                rebounds: c.rebounds,
                assists: c.assists
            )
        }
    }
    
    private func getPrimaryBroadcaster(_ broadcasters: Broadcasters?) -> String {
        guard let broadcasters = broadcasters else { return "League Pass" }
        
        if let national = broadcasters.nationalBroadcasters?.first?.broadcastDisplay {
            if national.uppercased() == "AMAZON" { return "Prime Video" }
            return national
        }
        
        if let ott = broadcasters.nationalOttBroadcasters?.first?.broadcastDisplay {
            return ott
        }
        
        return "League Pass"
    }
    
    private func formattedDate(offset: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
