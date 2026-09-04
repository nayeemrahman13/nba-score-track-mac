import Foundation
import ServiceManagement

/// Manages the "Launch at Login" functionality using the modern ServiceManagement framework.
/// Works on macOS 13+ without requiring a helper app.
class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()
    
    @Published var isEnabled: Bool {
        didSet {
            if isEnabled {
                enable()
            } else {
                disable()
            }
        }
    }
    
    private init() {
        // Check current status on init
        if #available(macOS 13.0, *) {
            isEnabled = SMAppService.mainApp.status == .enabled
        } else {
            isEnabled = false
        }
    }
    
    private func enable() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                print("Failed to enable launch at login: \(error)")
                isEnabled = false
            }
        }
    }
    
    private func disable() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                print("Failed to disable launch at login: \(error)")
            }
        }
    }
}
