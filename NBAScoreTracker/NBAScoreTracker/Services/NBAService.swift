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
    private var revisions: [String: UUID] = [:]
    private var failureCounts: [String: Int] = [:]
    private var isPopoverVisible = false
    private var selectedOffset = 0

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
        let dates = [0, -1, 1].map { ScoreDate.key(offset: $0, now: now) }
        let selectedDate = ScoreDate.key(offset: selectedOffset, now: now)
        games = games.filter { dates.contains($0.key) }
        updatedAt = updatedAt.filter { dates.contains($0.key) }
        errors = errors.filter { dates.contains($0.key) }
        failureCounts = failureCounts.filter { dates.contains($0.key) }
        for date in Array(leaderTasks.keys) where !dates.contains(date) {
            leaderTasks.removeValue(forKey: date)?.cancel()
            revisions.removeValue(forKey: date)
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
                group.addTask {
                    do { return (date, .success(try await client.scoreboard(for: date))) }
                    catch { return (date, .failure(error)) }
                }
            }
            for await (date, result) in group {
                guard !Task.isCancelled else { return }
                receive(result, for: date)
            }
        }
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
                return game
            }.sorted { a, b in
                let left = order[a.id] ?? Int.max, right = order[b.id] ?? Int.max
                if left != right { return left < right }
                if a.gameTimeUTC != b.gameTimeUTC { return a.gameTimeUTC < b.gameTimeUTC }
                return a.id < b.id
            }
            updatedAt[date] = now()
            errors.removeValue(forKey: date)
            failureCounts.removeValue(forKey: date)
            enrich(date: date)
        }
    }

    private func enrich(date: String) {
        // Let a bounded enrichment batch finish even if scores refresh again.
        guard leaderTasks[date] == nil else { return }
        let revision = UUID()
        revisions[date] = revision
        let candidates = (games[date] ?? []).filter { $0.status != .upcoming }
        let client = self.client
        leaderTasks[date] = Task { [weak self] in
            // Limit concurrent detail requests rather than enqueueing every game.
            await withTaskGroup(of: (String, CachedBoxScore?).self) { group in
                var iterator = candidates.makeIterator()
                func enqueue(_ game: Game) {
                    group.addTask { (game.id, try? await client.leaders(for: game)) }
                }
                for _ in 0..<3 { if let game = iterator.next() { enqueue(game) } }
                for await (id, box) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if let self, self.revisions[date] == revision, let box,
                       let index = self.games[date]?.firstIndex(where: { $0.id == id }),
                       let requested = candidates.first(where: { $0.id == id }),
                       self.games[date]?[index].status == requested.status {
                        self.games[date]?[index].homeTeam.leaders = box.homeTeam.leaders
                        self.games[date]?[index].awayTeam.leaders = box.awayTeam.leaders
                    }
                    if let game = iterator.next() { enqueue(game) }
                }
            }
            if self?.revisions[date] == revision { self?.leaderTasks.removeValue(forKey: date) }
        }
    }
}
