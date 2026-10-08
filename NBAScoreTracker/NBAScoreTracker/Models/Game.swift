import Foundation

// MARK: - CDN Scoreboard Response (cdn.nba.com - more reliable)
struct CDNScoreboardResponse: Codable {
    let scoreboard: CDNScoreboard
}

struct CDNScoreboard: Codable {
    let gameDate: String?
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
    let gameId: String?
    let gameStatus: Int?
    let homeTeam: BoxscoreTeam?
    let awayTeam: BoxscoreTeam?
}

struct BoxscoreTeam: Codable {
    let teamTricode: String?
    let score: Int?
    let players: [BoxscorePlayer]?
}

struct BoxscorePlayer: Codable {
    let personId: Int?
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
    var homeTeam: Team
    var awayTeam: Team
    let period: Int
    let gameTimeUTC: String

    var startDate: Date? { ScoreDate.tipoffDate(from: gameTimeUTC) }
    
    enum GameStatus: Int {
        case upcoming = 1
        case live = 2
        case finished = 3
    }
}

struct Team: Identifiable {
    var id: String { tricode }
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
    var id: String = UUID().uuidString
    let name: String
    let nameI: String
    let position: String
    let points: Int
    let rebounds: Int
    let assists: Int
}

// Tabs use local calendar days. Transport dates belong to the league's Eastern
// calendar and are converted separately before games are grouped by tipoff.
enum ScoreDate {
    static let upcomingOffsets = [1, 2, 3]
    static let trackedOffsets = [0, -1] + upcomingOffsets

    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func formatter(in timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func date(for key: String, timeZone: TimeZone = Calendar.current.timeZone) -> Date? {
        let formatter = formatter(in: timeZone)
        guard let date = formatter.date(from: key), formatter.string(from: date) == key else { return nil }
        return date
    }

    static func interval(for key: String, timeZone: TimeZone = Calendar.current.timeZone) -> DateInterval? {
        guard let date = date(for: key, timeZone: timeZone) else { return nil }
        return calendar(in: timeZone).dateInterval(of: .day, for: date)
    }

    static func key(offset: Int = 0, now: Date = Date(), timeZone: TimeZone = Calendar.current.timeZone) -> String {
        let calendar = calendar(in: timeZone)
        let date = calendar.date(byAdding: .day, value: offset, to: now) ?? now
        return formatter(in: timeZone).string(from: date)
    }

    static func tipoffDate(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

struct LeagueDate: Hashable {
    let key: String
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    init(containing date: Date) {
        key = ScoreDate.key(now: date, timeZone: Self.calendar.timeZone)
    }

    static func covering(_ interval: DateInterval) -> [LeagueDate] {
        let calendar = Self.calendar
        var day = calendar.startOfDay(for: interval.start)
        var dates: [LeagueDate] = []
        while day < interval.end {
            dates.append(LeagueDate(containing: day))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return dates
    }
}
