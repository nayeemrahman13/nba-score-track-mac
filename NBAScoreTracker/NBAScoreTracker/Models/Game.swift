import Foundation

enum NBAFeedLimits {
    static let responseBytes = 2 * 1024 * 1024
    static let games = 64
    static let playersPerTeam = 64

    static func isGameID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func isTricode(_ value: String) -> Bool {
        (2...4).contains(value.utf8.count) && value.utf8.allSatisfy { (65...90).contains($0) }
    }

    static func isText(_ value: String?, maximumBytes: Int = 256) -> Bool {
        value.map { $0.utf8.count <= maximumBytes } ?? true
    }
}

// MARK: - CDN Scoreboard Response (cdn.nba.com - more reliable)
struct CDNScoreboardResponse: Codable, Sendable {
    let scoreboard: CDNScoreboard
}

struct CDNScoreboard: Codable, Sendable {
    let gameDate: String?
    let games: [CDNGame]
}

struct CDNGame: Codable, Sendable {
    let gameId: String
    let gameStatus: Int
    let gameStatusText: String
    let period: Int
    let gameTimeUTC: String?
    let homeTeam: CDNTeam
    let awayTeam: CDNTeam
    let broadcasters: CDNBroadcasters?
    var gameClock: String? = nil
}

struct CDNTeam: Codable, Sendable {
    let teamTricode: String?
    let score: Int?
}

struct CDNBroadcasters: Codable, Sendable {
    let nationalTvBroadcasters: [CDNBroadcaster]?
    let nationalRadioBroadcasters: [CDNBroadcaster]?
    let homeTvBroadcasters: [CDNBroadcaster]?
    let awayTvBroadcasters: [CDNBroadcaster]?
}

struct CDNBroadcaster: Codable, Sendable {
    let broadcasterDisplay: String?
}

// MARK: - Legacy Scoreboard Response (stats.nba.com - often blocked)
struct ScoreboardResponse: Codable, Sendable {
    let scoreboard: Scoreboard
}

struct Scoreboard: Codable, Sendable {
    let games: [APIGame]
}

struct APIGame: Codable, Sendable {
    let gameId: String
    let gameStatus: Int
    let gameStatusText: String
    let period: Int
    let gameTimeUTC: String?
    let homeTeam: APITeam
    let awayTeam: APITeam
    let broadcasters: Broadcasters?
    var gameClock: String? = nil
}

struct APITeam: Codable, Sendable {
    let teamTricode: String?
    let score: Int?
}

struct Broadcasters: Codable, Sendable {
    let nationalBroadcasters: [Broadcaster]?
    let nationalOttBroadcasters: [Broadcaster]?
}

struct Broadcaster: Codable, Sendable {
    let broadcastDisplay: String?
}

// MARK: - Boxscore Response
struct BoxscoreResponse: Codable, Sendable {
    let game: BoxscoreGame?
}

struct BoxscoreGame: Codable, Sendable {
    let gameId: String?
    let gameStatus: Int?
    let gameStatusText: String?
    let period: Int?
    let gameClock: String?
    let homeTeam: BoxscoreTeam?
    let awayTeam: BoxscoreTeam?
}

struct BoxscoreTeam: Codable, Sendable {
    let teamTricode: String?
    let score: Int?
    let players: [BoxscorePlayer]?
}

struct BoxscorePlayer: Codable, Sendable {
    let personId: Int?
    let name: String?
    let nameI: String?
    let position: String?
    let statistics: PlayerStatistics?
}

struct PlayerStatistics: Codable, Sendable {
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
struct Game: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var status: GameStatus
    var statusText: String
    var broadcaster: String
    var homeTeam: Team
    var awayTeam: Team
    var period: Int
    var gameClock: String
    let gameTimeUTC: String
    let startDate: Date?
    var isLoadingLeaders = false

    private enum CodingKeys: String, CodingKey {
        case id, status, statusText, broadcaster, homeTeam, awayTeam
        case period, gameClock, gameTimeUTC, startDate
    }

    init(
        id: String,
        status: GameStatus,
        statusText: String,
        broadcaster: String,
        homeTeam: Team,
        awayTeam: Team,
        period: Int,
        gameTimeUTC: String,
        startDate: Date? = nil,
        isLoadingLeaders: Bool = false,
        gameClock: String = ""
    ) {
        self.id = id
        self.status = status
        self.statusText = statusText
        self.broadcaster = broadcaster
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.period = period
        self.gameClock = gameClock
        self.gameTimeUTC = gameTimeUTC
        self.startDate = startDate ?? ScoreDate.tipoffDate(from: gameTimeUTC)
        self.isLoadingLeaders = isLoadingLeaders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(GameStatus.self, forKey: .status)
        statusText = try container.decode(String.self, forKey: .statusText)
        broadcaster = try container.decode(String.self, forKey: .broadcaster)
        homeTeam = try container.decode(Team.self, forKey: .homeTeam)
        awayTeam = try container.decode(Team.self, forKey: .awayTeam)
        period = try container.decode(Int.self, forKey: .period)
        gameClock = try container.decode(String.self, forKey: .gameClock)
        gameTimeUTC = try container.decode(String.self, forKey: .gameTimeUTC)
        let decodedStart = try container.decodeIfPresent(Date.self, forKey: .startDate)
        startDate = decodedStart ?? ScoreDate.tipoffDate(from: gameTimeUTC)
        isLoadingLeaders = false
    }
    
    enum GameStatus: Int, Codable, Equatable, Sendable {
        case upcoming = 1
        case live = 2
        case finished = 3
    }

    /// Positive when `progress` is further into the game than this row, negative
    /// when it is behind, zero when they describe the same moment.
    func compareProgress(_ progress: GameProgress) -> Int {
        if progress.status != status { return progress.status.rawValue > status.rawValue ? 1 : -1 }
        if progress.period != period { return progress.period > period ? 1 : -1 }
        if let mine = GameProgress.seconds(fromClock: gameClock),
           let theirs = GameProgress.seconds(fromClock: progress.gameClock), mine != theirs {
            return theirs < mine ? 1 : -1
        }
        // A final row with the same period and clock is the official result;
        // a points difference there is a correction, not progress.
        guard status != .finished else { return 0 }
        let mine = homeTeam.score + awayTeam.score
        let theirs = progress.homeScore + progress.awayScore
        return theirs == mine ? 0 : theirs > mine ? 1 : -1
    }

    mutating func apply(_ progress: GameProgress) {
        status = progress.status
        statusText = progress.statusText.isEmpty ? statusText : progress.statusText
        period = progress.period
        gameClock = progress.gameClock
        homeTeam = Team(tricode: homeTeam.tricode, score: progress.homeScore, leaders: homeTeam.leaders)
        awayTeam = Team(tricode: awayTeam.tricode, score: progress.awayScore, leaders: awayTeam.leaders)
    }
}

/// Game state from a box score. The scoreboard feeds can lag the box score by
/// minutes (including staying live after the final buzzer), so a box score that
/// is further along supplies the displayed score, status and clock.
struct GameProgress: Codable, Equatable, Sendable {
    let status: Game.GameStatus
    let statusText: String
    let period: Int
    let gameClock: String
    let homeScore: Int
    let awayScore: Int

    /// Seconds left in the period from an ISO-8601 clock such as "PT05M42.00S".
    static func seconds(fromClock clock: String) -> Double? {
        let value = clock.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("PT"), value.hasSuffix("S"), let m = value.firstIndex(of: "M") else { return nil }
        guard let minutes = Double(value[value.index(value.startIndex, offsetBy: 2)..<m]),
              let seconds = Double(value[value.index(after: m)..<value.index(before: value.endIndex)]),
              minutes >= 0, seconds >= 0 else { return nil }
        return minutes * 60 + seconds
    }
}

struct Team: Identifiable, Codable, Equatable, Sendable {
    var id: String { tricode }
    let tricode: String
    let score: Int
    var leaders: [Player]
    
    var logoURL: URL? {
        guard NBAFeedLimits.isTricode(tricode) else { return nil }
        let mapping = ["UTA": "utah", "NOP": "no"]
        let filename = mapping[tricode] ?? tricode.lowercased()
        return URL(string: "https://a.espncdn.com/i/teamlogos/nba/500/scoreboard/\(filename).png")
    }
}

struct Player: Identifiable, Codable, Equatable, Sendable {
    var id: String = UUID().uuidString
    let name: String
    let nameI: String
    let position: String
    let points: Int
    let rebounds: Int
    let assists: Int
    var steals: Int = 0
    var blocks: Int = 0
    var minutes: String = ""
    var fgm: Int = 0
    var fga: Int = 0
    var threePm: Int = 0
    var threePa: Int = 0
    var ftm: Int = 0
    var fta: Int = 0

    var formattedMinutes: String? {
        // Convert ISO-8601 duration "PT34M12.00S" or "34:12" to compact minutes
        let trimmed = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("PT") {
            let body = trimmed.dropFirst(2)
            if let mIndex = body.firstIndex(of: "M") {
                let mins = String(body[..<mIndex])
                if let m = Int(mins), m > 0 { return "\(m) MIN" }
                if mins == "0", let sIndex = body.firstIndex(of: "S"),
                   let secs = Double(body[body.index(after: mIndex)..<sIndex]), secs > 0 {
                    return "<1 MIN"
                }
                return nil
            }
        }
        if let m = Int(trimmed.split(separator: ":").first ?? ""), m > 0 {
            return "\(m) MIN"
        }
        return nil
    }

    var detailTooltip: String {
        var parts = [name]
        if !position.isEmpty { parts[0] += " (\(position))" }
        if let minText = formattedMinutes { parts.append(minText) }
        if fga > 0 { parts.append("FG \(fgm)-\(fga)") }
        if threePa > 0 { parts.append("3PT \(threePm)-\(threePa)") }
        if fta > 0 { parts.append("FT \(ftm)-\(fta)") }
        if steals > 0 { parts.append("\(steals) STL") }
        if blocks > 0 { parts.append("\(blocks) BLK") }
        return parts.joined(separator: " · ")
    }
}

// Tabs use local calendar days. Transport dates belong to the league's Eastern
// calendar and are converted separately before games are grouped by tipoff.
enum ScoreDate {
    static let upcomingOffsets = [1, 2, 3]
    static let trackedOffsets = [0, -1] + upcomingOffsets

    private final class FormatterCache: @unchecked Sendable {
        let lock = NSLock()
        let isoFormatter = ISO8601DateFormatter()
        let isoFractionalFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter
        }()
        var dateToolsByTimeZone: [TimeZone: (calendar: Calendar, formatter: DateFormatter)] = [:]

        /// Caller must hold `lock`.
        func dateTools(in timeZone: TimeZone) -> (calendar: Calendar, formatter: DateFormatter) {
            if timeZone != .autoupdatingCurrent, let cached = dateToolsByTimeZone[timeZone] {
                return cached
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let tools = (calendar: calendar, formatter: formatter)
            if timeZone != .autoupdatingCurrent {
                if dateToolsByTimeZone.count >= 16 {
                    dateToolsByTimeZone.removeAll(keepingCapacity: true)
                }
                dateToolsByTimeZone[timeZone] = tools
            }
            return tools
        }
    }

    private static let cache = FormatterCache()

    static func date(for key: String, timeZone: TimeZone = Calendar.current.timeZone) -> Date? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        let formatter = cache.dateTools(in: timeZone).formatter
        guard let date = formatter.date(from: key), formatter.string(from: date) == key else { return nil }
        return date
    }

    static func interval(for key: String, timeZone: TimeZone = Calendar.current.timeZone) -> DateInterval? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        let tools = cache.dateTools(in: timeZone)
        guard let date = tools.formatter.date(from: key), tools.formatter.string(from: date) == key else { return nil }
        return tools.calendar.dateInterval(of: .day, for: date)
    }

    static func key(offset: Int = 0, now: Date = Date(), timeZone: TimeZone = Calendar.current.timeZone) -> String {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        let tools = cache.dateTools(in: timeZone)
        let date = offset == 0 ? now : (tools.calendar.date(byAdding: .day, value: offset, to: now) ?? now)
        return tools.formatter.string(from: date)
    }

    static func tipoffDate(from value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let date = cache.isoFormatter.date(from: value) { return date }
        return cache.isoFractionalFormatter.date(from: value)
    }
}

struct LeagueDate: Hashable, Sendable {
    let key: String
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    init(containing date: Date) {
        key = ScoreDate.key(now: date, timeZone: Self.calendar.timeZone)
    }

    /// The NBA's live CDN scoreboard stays on the active game night past
    /// Eastern midnight (9 PM Pacific) until midday Eastern the next day.
    static func mayUseLiveCDN(_ date: LeagueDate, now: Date) -> Bool {
        date == LeagueDate(containing: now)
            || date == LeagueDate(containing: now.addingTimeInterval(-12 * 3600))
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
