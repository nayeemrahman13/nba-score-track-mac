import Foundation
import Combine

/// Owns UI state and decoupled scoreboard refreshes (foreground Today/Yesterday
/// vs. on-demand future days +1..+3). Box scores are independent enrichment;
/// they never write scores or block scoreboard updates.
@MainActor
final class NBAService: ObservableObject {
    private struct SettledFinal: Equatable {
        let homeScore: Int
        let awayScore: Int
        let settledAt: Date
    }

    static let settledYesterdayInterval: TimeInterval = 1800
    static let settledYesterdayCutoffHours: TimeInterval = 3 * 3600

    @Published private(set) var games: [String: [Game]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var updatedAt: [String: Date] = [:]
    @Published private(set) var loadingDates: Set<String> = []
    @Published private(set) var day = ScoreDate.key()
    @Published private(set) var isOnline = true

    private let client: any NBAFetching
    private let now: () -> Date
    private let networkMonitor: any NetworkMonitoring
    private let snapshotCache: ScoreboardSnapshotCache?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var lifecycleGeneration: UInt64 = 0
    private var foregroundRefreshTask: Task<Void, Never>?
    private var needsRefreshCheck = false
    private var futureTasks: [String: Task<Void, Never>] = [:]
    private var futureNeedsCheck: Set<String> = []
    private var foregroundLoadingDates: Set<String> = []
    private var futureLoadingDates: Set<String> = []
    private var pollingTask: Task<Void, Never>?
    private var leaderTasks: [String: Task<Void, Never>] = [:]
    private var needsLeaderEnrichment: Set<String> = []
    private var interruptedLeaderDates: Set<String> = []
    private var revisions: [String: UUID] = [:]
    // Latest accepted box-score state per game, reapplied while the scoreboard lags.
    private var progressByGame: [String: GameProgress] = [:]
    // Final games whose scoreboard and box score both confirmed matching totals
    // and populated leaders; skipped on subsequent polls until TTL or score change.
    private var settledFinals: [String: SettledFinal] = [:]
    private var expandedGames: Set<String> = []
    private var failureCounts: [String: Int] = [:]
    private var attemptedAt: [String: Date] = [:]
    private var isPopoverVisible = false
    private var selectedOffset = 0

    var upcomingDates: [String] {
        let reference = ScoreDate.date(for: day) ?? now()
        return ScoreDate.upcomingOffsets.map { ScoreDate.key(offset: $0, now: reference) }
    }

    var hasLiveGames: Bool { games.values.joined().contains { $0.status == .live } }
    var pollingInterval: TimeInterval {
        hasLiveGames ? 15 : errors.isEmpty ? 60 : 30
    }

    init(
        client: any NBAFetching = NBAClient(),
        now: @escaping () -> Date = Date.init,
        networkMonitor: any NetworkMonitoring = LiveNetworkMonitor(),
        snapshotCache: ScoreboardSnapshotCache? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.client = client
        self.now = now
        self.networkMonitor = networkMonitor
        self.snapshotCache = snapshotCache
        self.sleep = sleep
        let initialNow = now()
        self.day = ScoreDate.key(now: initialNow)
        if let snapshot = snapshotCache?.load(now: initialNow) {
            let tracked = Set(ScoreDate.trackedOffsets.map { ScoreDate.key(offset: $0, now: initialNow) })
            let hydratedGames = snapshot.games.filter { tracked.contains($0.key) }
            self.games = hydratedGames
            self.updatedAt = snapshot.updatedAt.filter { tracked.contains($0.key) && hydratedGames[$0.key] != nil }
            let trackedGameIDs = Set(hydratedGames.values.joined().map(\.id))
            var hydratedProgress = (snapshot.progressByGame ?? [:]).filter { trackedGameIDs.contains($0.key) }
            // Preserve no-backward-score provenance for all hydrated live/final
            // games until a fresh scoreboard matches or surpasses them.
            for game in hydratedGames.values.joined() where game.status != .upcoming && hydratedProgress[game.id] == nil {
                hydratedProgress[game.id] = GameProgress(
                    status: game.status,
                    statusText: game.statusText,
                    period: game.period,
                    gameClock: game.gameClock,
                    homeScore: game.homeTeam.score,
                    awayScore: game.awayTeam.score
                )
            }
            self.progressByGame = hydratedProgress
        }
        self.isOnline = networkMonitor.isSatisfied
        networkMonitor.start { [weak self] online in
            Task { @MainActor [weak self] in
                self?.handleConnectivityChange(online)
            }
        }
    }

    deinit {
        networkMonitor.stop()
        pollingTask?.cancel()
        foregroundRefreshTask?.cancel()
        futureTasks.values.forEach { $0.cancel() }
        leaderTasks.values.forEach { $0.cancel() }
    }

    func setExpandedGames(_ ids: Set<String>) {
        expandedGames = ids
    }

    func setPopoverVisible(_ visible: Bool) {
        updateDay(ScoreDate.key(now: now()))
        if visible {
            selectedOffset = 0
            updateLoadingState()
        }
        let hasActiveWork = pollingTask != nil
            || foregroundRefreshTask != nil
            || !futureTasks.isEmpty
            || !leaderTasks.isEmpty
        guard isPopoverVisible != visible
            || (visible && pollingTask == nil && isOnline)
            || (!visible && hasActiveWork) else { return }
        isPopoverVisible = visible
        if visible {
            restartPolling()
        } else {
            pauseWork()
        }
    }

    func selectDate(offset: Int) {
        updateDay(ScoreDate.key(now: now()))
        selectedOffset = offset
        updateLoadingState()
        guard isPopoverVisible && isOnline else { return }
        restartPolling()
    }

    func resume() {
        // Sleep and wall-clock changes invalidate attempt-based freshness.
        NSTimeZone.resetSystemTimeZone()
        updateDay(ScoreDate.key(now: now()))
        attemptedAt.removeAll()
        if isPopoverVisible && isOnline {
            if foregroundRefreshTask != nil {
                needsRefreshCheck = true
            }
            restartPolling()
        } else {
            pauseWork()
        }
    }

    private func handleConnectivityChange(_ online: Bool) {
        let wasOnline = isOnline
        if isOnline != online { isOnline = online }
        if !online {
            pauseWork()
        } else if !wasOnline {
            failureCounts.removeAll()
            attemptedAt.removeAll()
            if isPopoverVisible {
                restartPolling()
            }
        }
    }

    /// Cancels all owned polling, scoreboard, future-lane, and box-score tasks
    /// and advances the lifecycle generation so in-flight completions cannot
    /// schedule enrichment or follow-up batches while hidden or offline.
    private func pauseWork() {
        lifecycleGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        needsRefreshCheck = false
        for task in futureTasks.values { task.cancel() }
        futureTasks.removeAll()
        futureNeedsCheck.removeAll()
        interruptedLeaderDates.formUnion(leaderTasks.keys)
        interruptedLeaderDates.formUnion(needsLeaderEnrichment)
        for task in leaderTasks.values { task.cancel() }
        leaderTasks.removeAll()
        revisions.removeAll()
        needsLeaderEnrichment.removeAll()
        for interruptedDate in foregroundLoadingDates.union(futureLoadingDates) {
            attemptedAt.removeValue(forKey: interruptedDate)
        }
        foregroundLoadingDates.removeAll()
        futureLoadingDates.removeAll()
        for (date, dayGames) in games where dayGames.contains(where: { $0.isLoadingLeaders }) {
            games[date] = dayGames.map { game in
                var copy = game
                copy.isLoadingLeaders = false
                return copy
            }
        }
        updateLoadingState()
    }

    private func updateDay(_ newDay: String) {
        if day != newDay { day = newDay }
    }

    private func updateLoadingState() {
        let combined = foregroundLoadingDates.union(futureLoadingDates)
        if loadingDates != combined { loadingDates = combined }
        let selectedDate = ScoreDate.key(offset: selectedOffset, now: now())
        let activeLoading = combined.contains(selectedDate)
            || (selectedOffset <= 0 && !foregroundLoadingDates.isEmpty)
        if isLoading != activeLoading { isLoading = activeLoading }
    }

    private func restartPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        guard isPopoverVisible, isOnline else { return }
        // Record this synchronously: the replacement polling task may not run
        // until an existing request has finished.
        if foregroundRefreshTask != nil {
            needsRefreshCheck = true
        }
        let sleepFn = self.sleep
        // Do not hold self during the sleep; the loop ends with the service.
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                // Trigger selected future day on its own decoupled lane without
                // blocking Today's polling cadence or sleep interval.
                self?.startFutureRefreshIfNeeded(force: false)
                await self?.runForegroundRefresh(force: false)
                guard let self, !Task.isCancelled, self.isPopoverVisible, self.isOnline else { return }
                self.resumeInterruptedEnrichment()
                let interval = self.nextPollDelay(at: self.now())
                do { try await sleepFn(interval) }
                catch { return }
            }
        }
    }

    func refreshAll(force: Bool = true) async {
        let selectedFutureDate: String? = selectedOffset > 0
            ? ScoreDate.key(offset: selectedOffset, now: now())
            : nil
        if let futureDate = selectedFutureDate {
            async let fg: Void = runForegroundRefresh(force: force)
            async let fut: Void = refreshFutureDate(futureDate, force: force)
            _ = await (fg, fut)
        } else {
            await runForegroundRefresh(force: force)
        }
    }

    private func startFutureRefreshIfNeeded(force: Bool) {
        guard selectedOffset > 0 else { return }
        let futureDate = ScoreDate.key(offset: selectedOffset, now: now())
        if futureTasks[futureDate] != nil {
            futureNeedsCheck.insert(futureDate)
            return
        }
        _ = ensureFutureTask(for: futureDate, force: force)
    }

    private func runForegroundRefresh(force: Bool) async {
        if let foregroundRefreshTask {
            needsRefreshCheck = true
            await foregroundRefreshTask.value
            return
        }
        let generation = lifecycleGeneration
        let task = Task { [weak self] in
            var forceNext = force
            repeat {
                guard let self, !Task.isCancelled, self.lifecycleGeneration == generation else { break }
                self.needsRefreshCheck = false
                await self.refreshForegroundDates(force: forceNext, generation: generation)
                // Joined callers request a fresh decision, not duplicate forced
                // requests. Cleared attempt times and changed dates are honored.
                forceNext = false
            } while !Task.isCancelled
                && self?.lifecycleGeneration == generation
                && self?.needsRefreshCheck == true
            // Clear ownership inside the shared task, before any waiter resumes,
            // only if this task still owns the active generation.
            if let self, self.lifecycleGeneration == generation {
                self.foregroundRefreshTask = nil
                self.foregroundLoadingDates.removeAll()
                self.updateLoadingState()
            }
        }
        foregroundRefreshTask = task
        await task.value
    }

    private func ensureFutureTask(for date: String, force: Bool) -> Task<Void, Never> {
        if let existing = futureTasks[date] {
            futureNeedsCheck.insert(date)
            return existing
        }
        let generation = lifecycleGeneration
        let task = Task { [weak self] in
            var forceNext = force
            repeat {
                guard let self, !Task.isCancelled, self.lifecycleGeneration == generation else { break }
                self.futureNeedsCheck.remove(date)
                await self.fetchSingleFutureDate(date, force: forceNext, generation: generation)
                forceNext = false
            } while !Task.isCancelled
                && self?.lifecycleGeneration == generation
                && self?.futureNeedsCheck.contains(date) == true
            if let self, self.lifecycleGeneration == generation {
                self.futureTasks.removeValue(forKey: date)
                self.futureLoadingDates.remove(date)
                self.updateLoadingState()
            }
        }
        futureTasks[date] = task
        return task
    }

    private func refreshFutureDate(_ date: String, force: Bool) async {
        let task = ensureFutureTask(for: date, force: force)
        await task.value
    }

    private func pruneUntrackedDates(at current: Date) -> Set<String> {
        let trackedSet = Set(ScoreDate.trackedOffsets.map { ScoreDate.key(offset: $0, now: current) })
        if games.keys.contains(where: { !trackedSet.contains($0) }) {
            games = games.filter { trackedSet.contains($0.key) }
        }
        if updatedAt.keys.contains(where: { !trackedSet.contains($0) }) {
            updatedAt = updatedAt.filter { trackedSet.contains($0.key) }
        }
        if errors.keys.contains(where: { !trackedSet.contains($0) }) {
            errors = errors.filter { trackedSet.contains($0.key) }
        }
        failureCounts = failureCounts.filter { trackedSet.contains($0.key) }
        attemptedAt = attemptedAt.filter { trackedSet.contains($0.key) }
        for date in Array(leaderTasks.keys) where !trackedSet.contains(date) {
            leaderTasks.removeValue(forKey: date)?.cancel()
            revisions.removeValue(forKey: date)
            needsLeaderEnrichment.remove(date)
        }
        interruptedLeaderDates = interruptedLeaderDates.filter { trackedSet.contains($0) }
        for date in Array(futureTasks.keys) where !trackedSet.contains(date) {
            futureTasks.removeValue(forKey: date)?.cancel()
            futureNeedsCheck.remove(date)
            futureLoadingDates.remove(date)
        }
        return trackedSet
    }

    private func isSettledYesterday(_ date: String, at current: Date, selectedDate: String) -> Bool {
        let yesterday = ScoreDate.key(offset: -1, now: current)
        guard date == yesterday,
              date != selectedDate,
              errors[date] == nil,
              let yesterdayGames = games[date],
              yesterdayGames.allSatisfy({ $0.status == .finished }),
              let todayStart = ScoreDate.interval(for: day)?.start,
              current.timeIntervalSince(todayStart) >= Self.settledYesterdayCutoffHours else {
            return false
        }
        return true
    }

    private func refreshInterval(for date: String, at current: Date, selectedDate: String) -> TimeInterval {
        let normalInterval: TimeInterval
        if date == day || date == selectedDate || games[date]?.contains(where: { $0.status == .live }) == true {
            normalInterval = pollingInterval
        } else if isSettledYesterday(date, at: current, selectedDate: selectedDate) {
            normalInterval = Self.settledYesterdayInterval
        } else {
            normalInterval = 300
        }
        let count = failureCounts[date] ?? 0
        return count > 0 ? min(300, 30 * pow(2, Double(min(count - 1, 4)))) : normalInterval
    }

    private func shouldRefresh(_ date: String, at current: Date, selectedDate: String, force: Bool) -> Bool {
        if force { return true }
        let interval = refreshInterval(for: date, at: current, selectedDate: selectedDate)
        // Failed requests retain their success timestamp, but use a separate
        // attempt time so joining callers cannot spin on the same failure.
        let latest = attemptedAt[date] ?? .distantPast
        return current.timeIntervalSince(latest) >= interval
    }

    /// Computes how long the polling loop should sleep before the next due
    /// foreground or selected date, preventing reopen/tab-switch overshoot
    /// while never spinning tighter than 1 second or waiting on blocked future lanes.
    private func nextPollDelay(at current: Date) -> TimeInterval {
        let cap = pollingInterval
        let trackedSet = Set(ScoreDate.trackedOffsets.map { ScoreDate.key(offset: $0, now: current) })
        let selectedDate = ScoreDate.key(offset: selectedOffset, now: current)
        var dueDates: [String] = [
            ScoreDate.key(offset: 0, now: current),
            ScoreDate.key(offset: -1, now: current)
        ]
        for date in trackedSet where !dueDates.contains(date) {
            let isLive = games[date]?.contains(where: { $0.status == .live }) == true
            if (isLive || date == selectedDate), futureTasks[date] == nil {
                dueDates.append(date)
            }
        }
        var shortest = cap
        for date in dueDates {
            let interval = refreshInterval(for: date, at: current, selectedDate: selectedDate)
            let elapsed = current.timeIntervalSince(attemptedAt[date] ?? .distantPast)
            let remaining = elapsed >= 0 ? (interval - elapsed) : interval
            shortest = min(shortest, remaining)
        }
        return min(cap, max(1, shortest))
    }

    private func resumeInterruptedEnrichment() {
        guard isPopoverVisible, isOnline, !interruptedLeaderDates.isEmpty else { return }
        let trackedSet = Set(ScoreDate.trackedOffsets.map { ScoreDate.key(offset: $0, now: now()) })
        let datesToResume = interruptedLeaderDates.filter { trackedSet.contains($0) }
        interruptedLeaderDates.removeAll()
        let generation = lifecycleGeneration
        for date in datesToResume {
            if let existing = games[date] {
                let updated = existing.map { game -> Game in
                    var copy = game
                    if copy.status != .upcoming && copy.homeTeam.leaders.isEmpty && copy.awayTeam.leaders.isEmpty {
                        copy.isLoadingLeaders = true
                    }
                    return copy
                }
                if updated != existing { games[date] = updated }
            }
            enrich(date: date, generation: generation)
        }
    }

    private func refreshForegroundDates(force: Bool, generation: UInt64) async {
        let current = now()
        updateDay(ScoreDate.key(now: current))
        let trackedSet = pruneUntrackedDates(at: current)
        let selectedDate = ScoreDate.key(offset: selectedOffset, now: current)

        // Foreground lane owns Today, Yesterday, and any already-loaded tracked
        // date that currently has live games. Unselected future days (+1..+3)
        // stay on-demand so slow stats calls never delay Today.
        var candidateDates: [String] = [
            ScoreDate.key(offset: 0, now: current),
            ScoreDate.key(offset: -1, now: current)
        ]
        for date in trackedSet where !candidateDates.contains(date) {
            if games[date]?.contains(where: { $0.status == .live }) == true,
               futureTasks[date] == nil {
                candidateDates.append(date)
            }
        }

        let requested = candidateDates.filter {
            shouldRefresh($0, at: current, selectedDate: selectedDate, force: force)
        }
        guard !requested.isEmpty else { return }
        requested.forEach { attemptedAt[$0] = current }
        foregroundLoadingDates = Set(requested)
        updateLoadingState()
        let client = self.client
        await withTaskGroup(of: (String, Result<[Game], Error>).self) { group in
            for date in requested {
                group.addTask { await Self.fetchScoreboard(client, date) }
            }
            for await (date, result) in group {
                guard !Task.isCancelled, self.lifecycleGeneration == generation else {
                    group.cancelAll()
                    return
                }
                foregroundLoadingDates.remove(date)
                receive(result, for: date, generation: generation)
            }
        }
    }

    private func fetchSingleFutureDate(_ date: String, force: Bool, generation: UInt64) async {
        let current = now()
        updateDay(ScoreDate.key(now: current))
        let trackedSet = pruneUntrackedDates(at: current)
        guard trackedSet.contains(date) else { return }
        let selectedDate = ScoreDate.key(offset: selectedOffset, now: current)
        guard shouldRefresh(date, at: current, selectedDate: selectedDate, force: force) else { return }
        attemptedAt[date] = current
        futureLoadingDates.insert(date)
        updateLoadingState()
        let (_, result) = await Self.fetchScoreboard(client, date)
        guard !Task.isCancelled, self.lifecycleGeneration == generation else { return }
        futureLoadingDates.remove(date)
        receive(result, for: date, generation: generation)
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

    private func receive(_ result: Result<[Game], Error>, for date: String, generation: UInt64) {
        guard lifecycleGeneration == generation else { return }
        updateLoadingState()
        switch result {
        case .failure(let error):
            failureCounts[date, default: 0] += 1
            let message = (error as? NBAError)?.errorDescription
                ?? "Couldn't update scores. Check your connection; we'll retry automatically."
            if errors[date] != message { errors[date] = message }
        case .success(let fetched):
            // Malformed duplicate IDs would otherwise break SwiftUI identity.
            guard Set(fetched.map(\.id)).count == fetched.count else {
                failureCounts[date, default: 0] += 1
                let message = NBAError.invalidResponse.errorDescription
                if errors[date] != message { errors[date] = message }
                return
            }
            let previous = games[date] ?? []
            let order = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element.id, $0.offset) })
            let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let merged = fetched.map { fresh in
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
                if let settled = settledFinals[game.id],
                   fresh.status != .finished
                    || settled.homeScore != fresh.homeTeam.score
                    || settled.awayScore != fresh.awayTeam.score {
                    settledFinals.removeValue(forKey: game.id)
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
            if games[date] != merged { games[date] = merged }
            let tracked = Set(games.values.joined().map(\.id))
            progressByGame = progressByGame.filter { tracked.contains($0.key) }
            settledFinals = settledFinals.filter { tracked.contains($0.key) }
            let timestamp = now()
            if updatedAt[date] != timestamp { updatedAt[date] = timestamp }
            if errors[date] != nil { errors.removeValue(forKey: date) }
            failureCounts.removeValue(forKey: date)
            interruptedLeaderDates.remove(date)
            snapshotCache?.scheduleSave(games: games, updatedAt: updatedAt, progressByGame: progressByGame)
            enrich(date: date, generation: generation)
        }
    }

    private func isSettledFinal(_ game: Game, at current: Date) -> Bool {
        guard game.status == .finished,
              progressByGame[game.id] == nil,
              !game.homeTeam.leaders.isEmpty,
              !game.awayTeam.leaders.isEmpty,
              let settled = settledFinals[game.id],
              settled.homeScore == game.homeTeam.score,
              settled.awayScore == game.awayTeam.score else { return false }
        let age = current.timeIntervalSince(settled.settledAt)
        return age >= 0 && age < BoxScoreCache.lifetime
    }

    private func enrichmentPriority(for game: Game) -> Int {
        let isExpanded = expandedGames.contains(game.id)
        let isActive = game.status != .finished || progressByGame[game.id] != nil
        switch (isExpanded, isActive) {
        case (true, true): return 0
        case (false, true): return 1
        case (true, false): return 2
        case (false, false): return 3
        }
    }

    private func popNextEnrichmentCandidate(from remaining: inout [Game]) -> Game? {
        guard !remaining.isEmpty else { return nil }
        let bestIndex = remaining.indices.min { lhs, rhs in
            let lp = enrichmentPriority(for: remaining[lhs])
            let rp = enrichmentPriority(for: remaining[rhs])
            return lp != rp ? lp < rp : lhs < rhs
        }!
        return remaining.remove(at: bestIndex)
    }

    private func enrich(date: String, generation: UInt64) {
        guard lifecycleGeneration == generation else { return }
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
            guard game.status != .upcoming || game.startDate.map({ $0 <= current }) == true else {
                return false
            }
            return !isSettledFinal(game, at: current)
        }
        guard !candidates.isEmpty else {
            needsLeaderEnrichment.remove(date)
            return
        }
        let client = self.client
        let requestedByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        leaderTasks[date] = Task { [weak self] in
            // Limit concurrent detail requests rather than enqueueing every game.
            await withTaskGroup(of: (String, CachedBoxScore?).self) { group in
                var remaining = candidates
                func enqueue(_ game: Game) {
                    group.addTask { await Self.fetchLeaders(client, game) }
                }
                for _ in 0..<3 {
                    if let game = self?.popNextEnrichmentCandidate(from: &remaining) { enqueue(game) }
                }
                for await (id, box) in group {
                    guard !Task.isCancelled, self?.lifecycleGeneration == generation else {
                        group.cancelAll()
                        return
                    }
                    if let self, self.revisions[date] == revision,
                       let index = self.games[date]?.firstIndex(where: { $0.id == id }),
                       let requested = requestedByID[id],
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
                            if self.games[date]?[index] != game {
                                self.games[date]?[index] = game
                                self.snapshotCache?.scheduleSave(
                                    games: self.games,
                                    updatedAt: self.updatedAt,
                                    progressByGame: self.progressByGame
                                )
                            }
                            if let box,
                               game.status == .finished,
                               self.progressByGame[id] == nil,
                               !game.homeTeam.leaders.isEmpty,
                               !game.awayTeam.leaders.isEmpty,
                               (box.progress == nil || box.progress?.status == .finished),
                               box.homeScore == game.homeTeam.score,
                               box.awayScore == game.awayTeam.score {
                                let settledAt = min(box.cachedAt, self.now())
                                self.settledFinals[id] = SettledFinal(
                                    homeScore: game.homeTeam.score,
                                    awayScore: game.awayTeam.score,
                                    settledAt: settledAt
                                )
                            }
                        }
                    }
                    if let self, self.lifecycleGeneration == generation,
                       let game = self.popNextEnrichmentCandidate(from: &remaining) {
                        enqueue(game)
                    }
                }
            }
            guard let self, self.revisions[date] == revision, self.lifecycleGeneration == generation else { return }
            self.leaderTasks.removeValue(forKey: date)
            if self.needsLeaderEnrichment.remove(date) != nil, !Task.isCancelled {
                self.enrich(date: date, generation: generation)
            }
        }
    }
}
