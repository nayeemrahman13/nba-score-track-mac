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
                .foregroundStyle(.secondary)
            
            Text("No games scheduled")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            
            Text("\(selectedDate). Check another day for matchups.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
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
        .background(.regularMaterial)
    }
    
    private var liveGames: [Game] { games.filter { $0.status == .live } }
    private var upcomingGames: [Game] { games.filter { $0.status == .upcoming } }
    private var finishedGames: [Game] { games.filter { $0.status == .finished } }
}

#Preview {
    GameListView(games: [], selectedDate: "Today")
}


/// Each date has its own loading/error/empty state so a failed request cannot
/// hide successfully loaded games from the other two upcoming days.
struct UpcomingGamesView: View {
    @EnvironmentObject var nbaService: NBAService
    let dates: [String]

    var body: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(dates, id: \.self) { date in
                Section {
                    if let games = nbaService.games[date] {
                        if let error = nbaService.errors[date] {
                            dayMessage("Couldn't refresh. Showing the last update.", icon: "exclamationmark.arrow.triangle.2.circlepath")
                                .help(error)
                        }
                        if games.isEmpty {
                            dayMessage("No games scheduled", icon: "calendar")
                        } else {
                            ForEach(games.sorted {
                                if $0.gameTimeUTC != $1.gameTimeUTC { return $0.gameTimeUTC < $1.gameTimeUTC }
                                return $0.id < $1.id
                            }) { game in
                                GameRowView(game: game)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                            }
                        }
                    } else if let error = nbaService.errors[date] {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Schedule unavailable", systemImage: "wifi.exclamationmark")
                            Text(error).foregroundStyle(.secondary)
                            Button("Try again") { Task { await nbaService.refreshAll() } }
                                .disabled(nbaService.isLoading)
                        }
                        .font(.system(size: 12))
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading games…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    HStack {
                        if let day = ScoreDate.date(for: date) {
                            Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                        } else {
                            Text(date)
                        }
                        Spacer()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                }
            }
        }
        .padding(.bottom, 8)
        .transaction { $0.animation = nil }
    }

    private func dayMessage(_ message: String, icon: String) -> some View {
        Label(message, systemImage: icon)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
