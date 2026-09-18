import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var launchManager = LaunchAtLoginManager.shared
    var onClose: () -> Void = {}
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close settings")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider()
            
            // Settings List
            VStack(spacing: 0) {
                settingRow(
                    icon: "power",
                    title: "Launch at Login",
                    subtitle: "Start NBA Tracker when you log in"
                ) {
                    Toggle("Launch at login", isOn: Binding(
                        get: { launchManager.isEnabled },
                        set: { launchManager.setEnabled($0) }
                    ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            .padding(.vertical, 8)
            
            Spacer()
            
            if launchManager.requiresApproval || launchManager.errorMessage != nil {
                VStack(spacing: 6) {
                    Text(launchManager.errorMessage ?? "Allow NBA Tracker in Login Items to finish setup.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Login Items") { launchManager.openSystemSettings() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            // App Info
            VStack(spacing: 4) {
                Text("NBA Score Tracker")
                    .font(.system(size: 11, weight: .medium))
                Text("Version 1.0")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        }
        .frame(width: 320, height: 250)
        .onAppear { launchManager.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchManager.refresh()
        }
        .background(.ultraThickMaterial)
    }
    
    private func settingRow<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

#Preview {
    SettingsView()
}

/// Settings must outlive the transient MenuBarExtra panel. Login-item system
/// notifications and approval UI can dismiss that panel by changing focus.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 250),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "NBA Tracker"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsView(onClose: { [weak self] in
            self?.close()
        }))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        LaunchAtLoginManager.shared.refresh()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
