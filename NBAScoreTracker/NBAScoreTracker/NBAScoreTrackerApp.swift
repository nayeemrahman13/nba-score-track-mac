import SwiftUI
import AppKit

@main
struct NBAScoreTrackerApp: App {
    @NSApplicationDelegateAdaptor(TrackerAppDelegate.self) private var appDelegate
    @StateObject private var nbaService = NBAService(snapshotCache: .shared)
    @StateObject private var updateManager = UpdateManager.shared
    
    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(nbaService)
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    nbaService.resume()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemClockDidChange)) { _ in
                    nbaService.resume()
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                    nbaService.resume()
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    nbaService.resume()
                }
        } label: {
            Image(systemName: updateManager.updateAvailable ? "arrow.down.circle.fill" : "basketball.fill")
                .symbolRenderingMode(.hierarchical)
                .help(updateManager.updateAvailable ? "NBA Tracker update available" : "NBA Tracker")
        }
        .menuBarExtraStyle(.window)
    }
}

// MenuBarExtra may retain its SwiftUI content while hiding the window, so
// onAppear/onDisappear alone cannot reliably reset navigation or update polling.
struct PopoverVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        private final class ObserverBag: @unchecked Sendable {
            private let lock = NSLock()
            private var tokens: [NSObjectProtocol] = []

            func replace(with newTokens: [NSObjectProtocol]) {
                lock.lock()
                let previous = tokens
                tokens = newTokens
                lock.unlock()
                previous.forEach { NotificationCenter.default.removeObserver($0) }
            }

            deinit {
                replace(with: [])
            }
        }

        var onChange: ((Bool) -> Void)?
        private let observers = ObserverBag()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var newTokens: [NSObjectProtocol] = []
            if let window {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                             NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                    newTokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.reportVisibility() }
                    })
                }
            }
            observers.replace(with: newTokens)
            Task { @MainActor [weak self] in self?.reportVisibility() }
        }

        private func reportVisibility() {
            onChange?(window?.isVisible == true && window?.occlusionState.contains(.visible) == true)
        }
    }
}
