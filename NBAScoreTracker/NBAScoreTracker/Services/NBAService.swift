import Foundation
import Combine

/// Owns UI state and exactly one scoreboard refresh at a time. Box scores are
/// independent enrichment; they never write scores or block scoreboard updates.
@MainActor
final class NBAService: ObservableObject {
    @Published private(set) var games: [String: [Game]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var updatedAt: [String: Date] = [:]
    @Published private(set) var loadingDates: Set<String> = []
    @Published private(set) var day = ScoreDate.key()

    private let client: any NBAFetching
    private let now: () -> Date
    private var refreshTask: Task<Void, Never>?
    private var needsRefreshCheck = false
    private var pollingTask: Task<Void, Never>?
    private var leaderTasks: [String: Task<Void, Never>] = [:]
    private var needsLeaderEnrichment: Set<String> = []
    private var revisions: [String: UUID] = [:]
    // Latest accepted box-score state per game, reapplied while the scoreboard lags.
    private var progressByGame: [String: GameProgress] = [:]
    private var failureCounts: [String: Int] = [:]
    private var isPopoverVisible = false
    private var selectedOffset = 0

    var upcomingDates: [String] {
        let reference = ScoreDate.date(for: day) ?? now()
        return ScoreDate.upcomingOffsets.map { ScoreDate.key(offset: $0, now: reference) }
    }

    var hasLiveGames: Bool { games.values.joined().contains { $0.status == .live } }
    var pollingInterval: TimeInterval {
        if isPopoverVisible { return hasLiveGames ? 15 : errors.isEmpty ? 60 : 30 }
        return hasLiveGames ? 300 : 900
    }

    init(client: any NBAFetching = NBAClient(), now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
        self.day = ScoreDate.key(now: now())
    }

    deinit {
        pollingTask?.cancel()
        refreshTask?.cancel()
        leaderTasks.values.forEach { $0.cancel() }
    }

    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible || pollingTask == nil else { return }
        isPopoverVisible = visible
        restartPolling()
    }

    func selectDate(offset: Int) {
        selectedOffset = offset
        restartPolling()
    }

    func resume() {
        // Sleep and wall-clock changes invalidate attempt-based freshness.
        day = ScoreDate.key(now: now())
        attemptedAt.removeAll()
        restartPolling()
    }

    private func restartPolling() {
        // Record this synchronously: the replacement polling task may not run
        // until an existing request has finished.
        needsRefreshCheck = true
        pollingTask?.cancel()
        // Do not hold self during the sleep; the loop ends with the service.
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll(force: false)
                guard let interval = self?.pollingInterval else { return }
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    func refreshAll(force: Bool = true) async {
        if let refreshTask {
            needsRefreshCheck = true
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            var forceNext = force
            repeat {
                self?.needsRefreshCheck = false
                await self?.refreshDates(force: forceNext)
                // Joined callers request a fresh decision, not duplicate forced
                // requests. Cleared attempt times and changed dates are honored.
                forceNext = false
            } while !Task.isCancelled && self?.needsRefreshCheck == true
            // Clear ownership inside the shared task, before any waiter resumes.
            self?.refreshTask = nil
            self?.isLoading = false
            self?.loadingDates = []
        }
        refreshTask = task
        await task.value
    }

    private func refreshDates(force: Bool) async {
        let now = now()
        day = ScoreDate.key(now: now)
        let dates = ScoreDate.trackedOffsets.map { ScoreDate.key(offset: $0, now: now) }
        let selectedDate = ScoreDate.key(offset: selectedOffset, now: now)
        games = games.filter { dates.contains($0.key) }
        updatedAt = updatedAt.filter { dates.contains($0.key) }
        errors = errors.filter { dates.contains($0.key) }
        failureCounts = failureCounts.filter { dates.contains($0.key) }
        for date in Array(leaderTasks.keys) where !dates.contains(date) {
            leaderTasks.removeValue(forKey: date)?.cancel()
            revisions.removeValue(forKey: date)
            needsLeaderEnrichment.remove(date)
        }
        let requested = dates.filter { date in
            if force { return true }
            let normalInterval: TimeInterval = date == day || date == selectedDate || games[date]?.contains(where: { $0.status == .live }) == true
                ? pollingInterval : 300
            let count = failureCounts[date] ?? 0
            let interval = count > 0 ? min(300, 30 * pow(2, Double(min(count - 1, 4)))) : normalInterval
            // Failed requests retain their success timestamp, but use a separate
            // attempt time so joining callers cannot spin on the same failure.
            let latest = attemptedAt[date] ?? .distantPast
            return now.timeIntervalSince(latest) >= interval
        }
        guard !requested.isEmpty else { return }
        attemptedAt = attemptedAt.filter { dates.contains($0.key) }
        requested.forEach { attemptedAt[$0] = now }
        isLoading = true
        loadingDates = Set(requested)
        let client = self.client
        await withTaskGroup(of: (String, Result<[Game], Error>).self) { group in
            for date in requested {
                group.addTask { await Self.fetchScoreboard(client, date) }
            }
            for await (date, result) in group {
                guard !Task.isCancelled else { return }
                receive(result, for: date)
            }
        }
    }

    // Child tasks must start from nonisolated functions. Closures written inside
    // these @MainActor task-group bodies crashed optimized builds on macOS 27
    // (Swift 6.4): a child completed after its group's storage had been freed
    // (EXC_BAD_ACCESS in swift::TaskGroup::offer).
    nonisolated private static func fetchScoreboard(_ client: any NBAFetching, _ date: String) async -> (String, Result<[Game], Error>) {
        do { return (date, .success(try await client.scoreboard(for: date))) }
        catch { return (date, .failure(error)) }
    }

    nonisolated private static func fetchLeaders(_ client: any NBAFetching, _ game: Game) async -> (String, CachedBoxScore?) {
        (game.id, try? await client.leaders(for: game))
    }

    private var attemptedAt: [String: Date] = [:]

    private func receive(_ result: Result<[Game], Error>, for date: String) {
        loadingDates.remove(date)
        switch result {
        case .failure(let error):
            failureCounts[date, default: 0] += 1
            errors[date] = (error as? NBAError)?.errorDescription
                ?? "Couldn't update scores. Check your connection; we'll retry automatically."
        case .success(let fetched):
            // Malformed duplicate IDs would otherwise break SwiftUI identity.
            guard Set(fetched.map(\.id)).count == fetched.count else {
                failureCounts[date, default: 0] += 1
                errors[date] = NBAError.invalidResponse.errorDescription
                return
            }
            let previous = games[date] ?? []
            let order = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element.id, $0.offset) })
            let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            games[date] = fetched.map { fresh in
                var game = fresh
                if let old = previousByID[game.id] {
                    game.homeTeam.leaders = old.homeTeam.leaders
                    game.awayTeam.leaders = old.awayTeam.leaders
                }
                if let progress = progressByGame[game.id] {
                    if game.compareProgress(progress) > 0 {
                        game.apply(progress)
                    } else {
                        progressByGame.removeValue(forKey: game.id)
                    }
                }
                game.isLoadingLeaders = game.status != .upcoming
                    && game.homeTeam.leaders.isEmpty
                    && game.awayTeam.leaders.isEmpty
                return game
            }.sorted { a, b in
                let left = order[a.id] ?? Int.max, right = order[b.id] ?? Int.max
                if left != right { return left < right }
                if a.gameTimeUTC != b.gameTimeUTC { return a.gameTimeUTC < b.gameTimeUTC }
                return a.id < b.id
            }
            let tracked = Set(games.values.joined().map(\.id))
            progressByGame = progressByGame.filter { tracked.contains($0.key) }
            updatedAt[date] = now()
            errors.removeValue(forKey: date)
            failureCounts.removeValue(forKey: date)
            enrich(date: date)
        }
    }

    private func enrich(date: String) {
        // Let a bounded enrichment batch finish even if scores refresh again,
        // and queue a follow-up pass so newly started/finished games are enriched.
        if leaderTasks[date] != nil {
            needsLeaderEnrichment.insert(date)
            return
        }
        let revision = UUID()
        revisions[date] = revision
        // A scoreboard that still says upcoming after tipoff may be lagging the box score.
        let current = now()
        let candidates = (games[date] ?? []).filter { game in
            game.status != .upcoming || game.startDate.map { $0 <= current } == true
        }
        guard !candidates.isEmpty else {
            needsLeaderEnrichment.remove(date)
            return
        }
        let client = self.client
        leaderTasks[date] = Task { [weak self] in
            // Limit concurrent detail requests rather than enqueueing every game.
            await withTaskGroup(of: (String, CachedBoxScore?).self) { group in
                var iterator = candidates.makeIterator()
                func enqueue(_ game: Game) {
                    group.addTask { await Self.fetchLeaders(client, game) }
                }
                for _ in 0..<3 { if let game = iterator.next() { enqueue(game) } }
                for await (id, box) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if let self, self.revisions[date] == revision,
                       let index = self.games[date]?.firstIndex(where: { $0.id == id }),
                       let requested = candidates.first(where: { $0.id == id }),
                       var game = self.games[date]?[index] {
                        // A box score behind the displayed state (for example, live
                        // details after the game is final) is never applied.
                        let accepted: Bool
                        if let progress = box?.progress {
                            let order = game.compareProgress(progress)
                            if order > 0 {
                                game.apply(progress)
                                self.progressByGame[id] = progress
                            }
                            accepted = order >= 0
                        } else {
                            accepted = game.status == requested.status
                        }
                        if accepted {
                            if let box, game.status != .upcoming {
                                game.homeTeam.leaders = box.homeTeam.leaders
                                game.awayTeam.leaders = box.awayTeam.leaders
                            }
                            game.isLoadingLeaders = false
                            self.games[date]?[index] = game
                        }
                    }
                    if let game = iterator.next() { enqueue(game) }
                }
            }
            guard let self, self.revisions[date] == revision else { return }
            self.leaderTasks.removeValue(forKey: date)
            if self.needsLeaderEnrichment.remove(date) != nil, !Task.isCancelled {
                self.enrich(date: date)
            }
        }
    }
}
