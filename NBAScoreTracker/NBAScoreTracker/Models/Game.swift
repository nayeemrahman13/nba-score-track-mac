import Foundation

// MARK: - CDN Scoreboard Response (cdn.nba.com - more reliable)
struct CDNScoreboardResponse: Codable {
    let scoreboard: CDNScoreboard
}

struct CDNScoreboard: Codable {
    let games: [CDNGame]
}

struct CDNGame: Codable {
    let gameId: String
    let gameStatus: Int
    let gameStatusText: String
    let period: Int
    let gameTimeUTC: String?
    let homeTeam: CDNTeam
    let awayTeam: CDNTeam
    let broadcasters: CDNBroadcasters?
}

struct CDNTeam: Codable {
    let teamTricode: String?
    let score: Int?
}

struct CDNBroadcasters: Codable {
    let nationalTvBroadcasters: [CDNBroadcaster]?
    let nationalRadioBroadcasters: [CDNBroadcaster]?
    let homeTvBroadcasters: [CDNBroadcaster]?
    let awayTvBroadcasters: [CDNBroadcaster]?
}

struct CDNBroadcaster: Codable {
    let broadcasterDisplay: String?
}

// MARK: - Legacy Scoreboard Response (stats.nba.com - often blocked)
struct ScoreboardResponse: Codable {
    let scoreboard: Scoreboard
}

struct Scoreboard: Codable {
    let games: [APIGame]
}

struct APIGame: Codable {
    let gameId: String
    let gameStatus: Int
    let gameStatusText: String
    let period: Int
    let gameTimeUTC: String?
    let homeTeam: APITeam
    let awayTeam: APITeam
    let broadcasters: Broadcasters?
}

struct APITeam: Codable {
    let teamTricode: String?
    let score: Int?
}

struct Broadcasters: Codable {
    let nationalBroadcasters: [Broadcaster]?
    let nationalOttBroadcasters: [Broadcaster]?
}

struct Broadcaster: Codable {
    let broadcastDisplay: String?
}

// MARK: - Boxscore Response
struct BoxscoreResponse: Codable {
    let game: BoxscoreGame?
}

struct BoxscoreGame: Codable {
    let homeTeam: BoxscoreTeam?
    let awayTeam: BoxscoreTeam?
}

struct BoxscoreTeam: Codable {
    let teamTricode: String?
    let score: Int?
    let players: [BoxscorePlayer]?
}

struct BoxscorePlayer: Codable {
    let name: String?
    let nameI: String?
    let position: String?
    let statistics: PlayerStatistics?
}

struct PlayerStatistics: Codable {
    let points: Int?
    let reboundsTotal: Int?
    let assists: Int?
    let steals: Int?
    let blocks: Int?
    let minutes: String?
    let fieldGoalsMade: Int?
    let fieldGoalsAttempted: Int?
    let threePointersMade: Int?
    let threePointersAttempted: Int?
    let freeThrowsMade: Int?
    let freeThrowsAttempted: Int?
}

// MARK: - App Models
struct Game: Identifiable {
    let id: String
    let status: GameStatus
    let statusText: String
    let broadcaster: String
    let homeTeam: Team
    let awayTeam: Team
    let period: Int
    let gameTimeUTC: String
    
    enum GameStatus: Int {
        case upcoming = 1
        case live = 2
        case finished = 3
    }
}

struct Team: Identifiable {
    let id = UUID()
    let tricode: String
    let score: Int
    var leaders: [Player]
    
    var logoURL: URL? {
        let mapping = ["UTA": "utah", "NOP": "no"]
        let filename = mapping[tricode] ?? tricode.lowercased()
        return URL(string: "https://a.espncdn.com/i/teamlogos/nba/500/scoreboard/\(filename).png")
    }
}

struct Player: Identifiable {
    let id = UUID()
    let name: String
    let nameI: String
    let position: String
    let points: Int
    let rebounds: Int
    let assists: Int
}
