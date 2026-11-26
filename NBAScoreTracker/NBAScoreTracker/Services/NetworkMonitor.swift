import Foundation
import Network

protocol NetworkMonitoring: AnyObject, Sendable {
    var isSatisfied: Bool { get }
    func start(onChange: @escaping @Sendable (Bool) -> Void)
    func stop()
}

/// Observes macOS network path reachability via `NWPathMonitor`.
/// Starts optimistic (`true`) until the system reports `.unsatisfied` so cold
/// launch never blocks waiting for the initial asynchronous path callback.
final class LiveNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.nayeemrahman.NBAScoreTracker.network", qos: .utility)
    private var monitor: NWPathMonitor?
    private var satisfied = true
    private var hasReported = false

    var isSatisfied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        guard monitor == nil else {
            lock.unlock()
            return
        }
        let pathMonitor = NWPathMonitor()
        monitor = pathMonitor
        lock.unlock()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let next = path.status == .satisfied
            self.lock.lock()
            let shouldNotify = !self.hasReported || self.satisfied != next
            self.hasReported = true
            self.satisfied = next
            self.lock.unlock()
            if shouldNotify {
                onChange(next)
            }
        }
        pathMonitor.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let active = monitor
        monitor = nil
        lock.unlock()
        active?.cancel()
    }

    deinit {
        stop()
    }
}
