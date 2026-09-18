import SwiftUI

struct ContentView: View {
    @EnvironmentObject var nbaService: NBAService
    @State private var selectedOffset = 0

    private var dateKey: String { ScoreDate.key(offset: selectedOffset) }
    private var selectedLabel: String { selectedOffset == 0 ? "Today" : selectedOffset < 0 ? "Yesterday" : "Tomorrow" }
    private var currentGames: [Game] { nbaService.games[dateKey] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Game date", selection: $selectedOffset) {
                Text("Yesterday").tag(-1)
                Text("Today").tag(0)
                Text("Tomorrow").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .onChange(of: selectedOffset) { nbaService.selectDate(offset: $0) }

            Divider()
            ScrollView {
                if nbaService.games[dateKey] == nil {
                    if let error = nbaService.errors[dateKey] {
                        stateView(icon: "wifi.exclamationmark", title: "Scores unavailable", detail: error, retry: true)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Loading scores…").font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 70)
                    }
                } else {
                    VStack(spacing: 0) {
                        if let error = nbaService.errors[dateKey] {
                            Label("Couldn't refresh. Showing the last update.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.08))
                                .help(error)
                        }
                        GameListView(games: currentGames, selectedDate: selectedLabel)
                    }
                }
            }
            .frame(height: 440)
            Divider()
            footer
        }
        .frame(width: 360)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NBA Tracker").font(.system(size: 15, weight: .semibold))
                Text(Calendar.current.date(byAdding: .day, value: selectedOffset, to: Date()) ?? Date(), format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await nbaService.refreshAll() }
            } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(nbaService.isLoading ? 0 : 1)
                    if nbaService.isLoading { ProgressView().controlSize(.small).scaleEffect(0.7) }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(nbaService.isLoading)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(nbaService.isLoading ? "Refreshing scores" : "Refresh scores")
            .help("Refresh scores (⌘R)")
            Button { SettingsWindowController.shared.show() } label: {
                Image(systemName: "gearshape").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Settings")
            .help("Settings")
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                if let updated = nbaService.updatedAt[dateKey] {
                    let stale = nbaService.errors[dateKey] != nil || context.date.timeIntervalSince(updated) > 120
                    HStack(spacing: 5) {
                        Circle().fill(stale ? Color.orange : Color.secondary).frame(width: 5, height: 5)
                        Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    }
                    .help(stale ? "Scores may be out of date. Refresh to try again." : "Scores refresh automatically while this window is open.")
                } else {
                    Text(nbaService.loadingDates.contains(dateKey) ? "Connecting to NBA…" : "Waiting for scores")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func stateView(icon: String, title: String, detail: String, retry: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if retry {
                Button("Try again") { Task { await nbaService.refreshAll() } }
                    .disabled(nbaService.isLoading)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity)
    }
}

#Preview { ContentView().environmentObject(NBAService()) }
