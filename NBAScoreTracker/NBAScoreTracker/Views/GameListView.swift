import SwiftUI

struct GameListView: View {
    let games: [Game]
    let selectedDate: String
    
    var body: some View {
        if games.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Live Games
                if !liveGames.isEmpty {
                    Section {
                        ForEach(liveGames) { game in
                            GameRowView(game: game)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                        }
                    } header: {
                        sectionHeader("Live", isLive: true)
                    }
                }
                
                // Upcoming Games
                if !upcomingGames.isEmpty {
                    Section {
                        ForEach(upcomingGames) { game in
                            GameRowView(game: game)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                        }
                    } header: {
                        sectionHeader("Upcoming")
                    }
                }
                
                // Finished Games
                if !finishedGames.isEmpty {
                    Section {
                        ForEach(finishedGames) { game in
                            GameRowView(game: game)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                        }
                    } header: {
                        sectionHeader("Final")
                    }
                }
            }
            .padding(.bottom, 8)
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sportscourt")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            
            Text("No Games")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            
            Text(selectedDate)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    private func sectionHeader(_ title: String, isLive: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
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
        .background(.ultraThickMaterial)
    }
    
    private var liveGames: [Game] { games.filter { $0.status == .live } }
    private var upcomingGames: [Game] { games.filter { $0.status == .upcoming } }
    private var finishedGames: [Game] { games.filter { $0.status == .finished } }
}

#Preview {
    GameListView(games: [], selectedDate: "Today")
}
