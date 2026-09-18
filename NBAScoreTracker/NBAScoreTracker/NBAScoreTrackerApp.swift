import SwiftUI
import AppKit

@main
struct NBAScoreTrackerApp: App {
    @StateObject private var nbaService = NBAService()
    
    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(nbaService)
                .background(PopoverVisibilityReader(onChange: nbaService.setPopoverVisible))
                .onAppear {
                    nbaService.setPopoverVisible(true)
                }
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
                .onDisappear {
                    nbaService.setPopoverVisible(false)
                }
        } label: {
            Image(systemName: "basketball.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}

// MenuBarExtra may retain its SwiftUI content while hiding the window, so
// onAppear/onDisappear alone are not a reliable signal for polling frequency.
private struct PopoverVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            if let window {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                             NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.reportVisibility() }
                    })
                }
            }
            Task { @MainActor [weak self] in self?.reportVisibility() }
        }

        private func reportVisibility() {
            onChange?(window?.isVisible == true && window?.occlusionState.contains(.visible) == true)
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
