import SwiftUI

struct SettingsView: View {
    @ObservedObject var launchManager = LaunchAtLoginManager.shared
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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
                    Toggle("", isOn: $launchManager.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            .padding(.vertical, 8)
            
            Spacer()
            
            // App Info
            VStack(spacing: 4) {
                Text("NBA Score Tracker")
                    .font(.system(size: 11, weight: .medium))
                Text("Version 1.0")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)
        }
        .frame(width: 300, height: 200)
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
                    .foregroundStyle(.tertiary)
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
