import SwiftUI

struct GameListView: View {
    let games: [Game]
    /// Completes "No games …", e.g. "today" or "on Saturday".
    let dayPhrase: String
    @Binding var expanded: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)
    }

    /// Changes only when a game changes section, so score updates stay still.
    private var sectionLayout: [String] { games.map { "\($0.id):\($0.status.rawValue)" } }

    var body: some View {
        if games.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                section("Live", games: liveGames, isLive: true)
                section("Upcoming", games: upcomingGames)
                section("Final", games: finishedGames)
            }
            .padding(.bottom, 8)
            .animation(motion, value: sectionLayout)
        }
    }

    @ViewBuilder
    private func section(_ title: String, games: [Game], isLive: Bool = false) -> some View {
        if !games.isEmpty {
            Section {
                ForEach(games) { game in
                    GameRowView(game: game, isExpanded: expanded.contains(game.id)) {
                        withAnimation(motion) { expanded.formSymmetricDifference([game.id]) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    // LazyVStack reuses a row's rendered view, without updating it,
                    // when its ID moves to another section's ForEach.
                    .id("\(game.id):\(game.status.rawValue)")
                    .transition(.opacity)
                }
            } header: {
                sectionHeader(title, isLive: isLive)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sportscourt")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.secondary)
            Text("No games \(dayPhrase)")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Pick another day above.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func sectionHeader(_ title: String, isLive: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if isLive {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        // One material layer over the scrolling rows; the panel itself uses
        // the menu bar window's own background rather than a second blur.
        .background(.bar)
    }

    private var liveGames: [Game] { games.filter { $0.status == .live } }
    private var upcomingGames: [Game] { games.filter { $0.status == .upcoming } }
    private var finishedGames: [Game] { games.filter { $0.status == .finished } }
}

#Preview {
    GameListView(games: [], dayPhrase: "today", expanded: .constant([]))
}
