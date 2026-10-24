import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var launchManager = LaunchAtLoginManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                        Text("Scores")
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to scores")
                .keyboardShortcut(.cancelAction)
                .help("Back to scores (Esc)")

                Spacer()

                Text("Settings")
                    .font(.headline)

                Spacer()

                // Balance leading button width so the title stays visually centered.
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                    Text("Scores")
                        .font(.subheadline)
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
            .padding(14)

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
                settingRow(
                    icon: "arrow.clockwise",
                    title: "Check for Updates",
                    subtitle: "Look for updates automatically"
                ) {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updateManager.automaticallyChecksForUpdates },
                        set: { updateManager.setAutomaticChecks($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                settingRow(
                    icon: "arrow.down.circle",
                    title: "Install Updates",
                    subtitle: "Download and install when you quit"
                ) {
                    Toggle("Download and install updates automatically", isOn: Binding(
                        get: { updateManager.automaticallyDownloadsUpdates },
                        set: { updateManager.setAutomaticDownloads($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!updateManager.automaticallyChecksForUpdates)
                }

                HStack {
                    Button(updateManager.updateAvailable ? "Install Available Update…" : "Check for Updates…") {
                        updateManager.checkForUpdates()
                    }
                    .disabled(!updateManager.canCheckForUpdates)
                }
                .padding(.top, 12)
            }
            .padding(.vertical, 8)

            if launchManager.requiresApproval || launchManager.errorMessage != nil {
                VStack(spacing: 6) {
                    Text(launchManager.errorMessage ?? "Allow NBA Tracker in Login Items to finish setup.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Login Items") { launchManager.openSystemSettings() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 16)

            // App Info
            VStack(spacing: 2) {
                Text("NBA Score Tracker")
                    .font(.subheadline.weight(.medium))
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .onAppear { launchManager.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchManager.refresh()
        }
    }

    private func settingRow<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
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
        .frame(width: 360)
}
