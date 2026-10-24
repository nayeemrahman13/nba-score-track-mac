import SwiftUI

struct ContentView: View {
    @EnvironmentObject var nbaService: NBAService
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var selectedOffset = 0
    // Lives above the rows so a game keeps its leaders open when it moves
    // between the Live, Upcoming and Final sections.
    @State private var expandedGames: Set<String> = []
    @State private var showingSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dayOffsets = ScoreDate.trackedOffsets.sorted()

    private var baseDate: Date { ScoreDate.date(for: nbaService.day) ?? Date() }
    private var dateKey: String { ScoreDate.key(offset: selectedOffset, now: baseDate) }
    private var selectedDay: Date { Calendar.current.date(byAdding: .day, value: selectedOffset, to: baseDate) ?? baseDate }
    private var currentGames: [Game] { nbaService.games[dateKey] ?? [] }
    private var dayPhrase: String {
        switch selectedOffset {
        case 0: return "today"
        case -1: return "yesterday"
        default: return "on " + selectedDay.formatted(.dateTime.weekday(.wide))
        }
    }

    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingSettings {
                SettingsView {
                    withAnimation(motion) { showingSettings = false }
                }
                .transition(.opacity)
            } else {
                header
                DayStrip(offsets: Self.dayOffsets, reference: baseDate, selection: $selectedOffset) { offset in
                    nbaService.games[ScoreDate.key(offset: offset, now: baseDate)]?.contains { $0.status == .live } == true
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
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
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.orange.opacity(0.08))
                                    .help(error)
                            }
                            // A new identity per day: switching days replaces the list
                            // instead of animating one day's rows into another's.
                            GameListView(games: currentGames, dayPhrase: dayPhrase, expanded: $expandedGames)
                                .id(dateKey)
                        }
                    }
                }
                .frame(height: 440)
            }
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NBA Tracker").font(.title3.weight(.semibold))
                Text(selectedDay, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await nbaService.refreshAll() }
            } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(nbaService.isLoading ? 0 : 1)
                    if nbaService.isLoading { ProgressView().controlSize(.mini) }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(nbaService.isLoading)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(nbaService.isLoading ? "Refreshing scores" : "Refresh scores")
            .help("Refresh scores (⌘R)")
            Button {
                withAnimation(motion) { showingSettings = true }
            } label: {
                Image(systemName: "gearshape").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Settings")
            .help("Settings (⌘,)")
        }
        .padding(14)
        .background {
            // Calendar-style ⌘← / ⌘→ day stepping. Zero opacity keeps the
            // shortcuts active, which .hidden() would not.
            HStack {
                Button("Previous day") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next day") { step(1) }.keyboardShortcut(.rightArrow, modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func step(_ delta: Int) {
        guard let index = Self.dayOffsets.firstIndex(of: selectedOffset) else { return }
        let next = min(max(index + delta, 0), Self.dayOffsets.count - 1)
        selectedOffset = Self.dayOffsets[next]
    }

    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                if let updated = nbaService.updatedAt[dateKey] {
                    let stale = nbaService.errors[dateKey] != nil || context.date.timeIntervalSince(updated) > 120
                    let time = updated.formatted(date: .omitted, time: .shortened)
                    HStack(spacing: 5) {
                        Circle().fill(stale ? Color.orange : Color.secondary).frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                        Text(stale ? "Updated \(time) · Out of date" : "Updated \(time)")
                    }
                    .help(stale ? "Scores may be out of date. Refresh to try again." : "Scores refresh automatically while this window is open.")
                } else {
                    Text(nbaService.loadingDates.contains(dateKey) ? "Connecting to NBA…" : "Waiting for scores")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Spacer()
            if updateManager.updateAvailable {
                Button("Update available…") { updateManager.checkForUpdates() }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .disabled(!updateManager.canCheckForUpdates)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func stateView(icon: String, title: String, detail: String, retry: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
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

/// One chip per tracked day, in the style of Apple Sports' schedule strip.
private struct DayStrip: View {
    let offsets: [Int]
    let reference: Date
    @Binding var selection: Int
    let hasLiveGames: (Int) -> Bool
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(offsets, id: \.self) { offset in
                DayChip(offset: offset,
                        day: Calendar.current.date(byAdding: .day, value: offset, to: reference) ?? reference,
                        isSelected: offset == selection,
                        isLive: hasLiveGames(offset),
                        highlight: highlight) {
                    selection = offset
                }
            }
        }
        // Scoped to the strip: only the highlight slides; the game list swaps at once.
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: selection)
    }
}

private struct DayChip: View {
    let offset: Int
    let day: Date
    let isSelected: Bool
    let isLive: Bool
    let highlight: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    private var title: String {
        switch offset {
        case 0: return "Today"
        case -1: return "Yesterday"
        default: return day.formatted(.dateTime.weekday(.abbreviated))
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text(day, format: .dateTime.day())
                    .font(.system(.title3, design: .rounded, weight: isSelected ? .semibold : .regular))
                    .monospacedDigit()
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.1))
                        .matchedGeometryEffect(id: "selection", in: highlight)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
            }
            .overlay(alignment: .topTrailing) {
                if isLive {
                    Circle().fill(.red).frame(width: 5, height: 5).padding(6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(DayChipButtonStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title), \(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))\(isLive ? ", live games" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Press feedback lands on pointer-down with no transition, like native controls.
private struct DayChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

#Preview { ContentView().environmentObject(NBAService()) }
