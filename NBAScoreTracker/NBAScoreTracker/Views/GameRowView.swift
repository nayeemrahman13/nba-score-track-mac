import SwiftUI

struct GameRowView: View {
    let game: Game
    @State private var isExpanded = false
    @State private var isHovering = false
    
    var body: some View {
        VStack(spacing: 0) {
            mainContent
            
            if isExpanded && game.status != .upcoming {
                expandedContent
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .onTapGesture {
            if game.status != .upcoming {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
        }
    }
    
    // MARK: - Main Content
    
    private var mainContent: some View {
        HStack(spacing: 12) {
            // Teams Column
            VStack(alignment: .leading, spacing: 4) {
                teamRow(game.homeTeam, isWinner: game.status == .finished && game.homeTeam.score > game.awayTeam.score)
                teamRow(game.awayTeam, isWinner: game.status == .finished && game.awayTeam.score > game.homeTeam.score)
            }
            
            Spacer()
            
            // Status Column
            VStack(alignment: .trailing, spacing: 4) {
                statusLabel
                if game.status == .upcoming {
                    broadcasterBadge
                }
            }
            
            // Expand indicator
            if game.status != .upcoming {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
    
    private func teamRow(_ team: Team, isWinner: Bool) -> some View {
        HStack(spacing: 8) {
            AsyncImage(url: team.logoURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 18, height: 18)
            
            Text(team.tricode)
                .font(.system(size: 13, weight: isWinner ? .bold : .medium))
                .frame(width: 36, alignment: .leading)
            
            if game.status != .upcoming {
                Text("\(team.score)")
                    .font(.system(size: 13, weight: isWinner ? .bold : .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isWinner ? .primary : .secondary)
            }
        }
    }
    
    @ViewBuilder
    private var statusLabel: some View {
        switch game.status {
        case .live:
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 5, height: 5)
                Text(game.statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
            }
        case .finished:
            Text("Final")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        case .upcoming:
            Text(game.statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
    
    private var broadcasterBadge: some View {
        Text(game.broadcaster)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
            )
    }
    
    // MARK: - Expanded Content
    
    private var expandedContent: some View {
        VStack(spacing: 8) {
            Divider()
                .padding(.horizontal, 8)
            
            if !game.homeTeam.leaders.isEmpty {
                LeadersView(teamName: game.homeTeam.tricode, leaders: game.homeTeam.leaders)
            }
            
            if !game.awayTeam.leaders.isEmpty {
                LeadersView(teamName: game.awayTeam.tricode, leaders: game.awayTeam.leaders)
            }
            
            if game.homeTeam.leaders.isEmpty && game.awayTeam.leaders.isEmpty {
                Text("Leaders unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

#Preview {
    VStack {
        GameRowView(game: Game(
            id: "1",
            status: .live,
            statusText: "Q3 5:42",
            broadcaster: "ESPN",
            homeTeam: Team(tricode: "LAL", score: 87, leaders: []),
            awayTeam: Team(tricode: "BOS", score: 92, leaders: []),
            period: 3,
            gameTimeUTC: ""
        ))
        
        GameRowView(game: Game(
            id: "2",
            status: .upcoming,
            statusText: "7:00 pm ET",
            broadcaster: "League Pass",
            homeTeam: Team(tricode: "MIA", score: 0, leaders: []),
            awayTeam: Team(tricode: "NYK", score: 0, leaders: []),
            period: 0,
            gameTimeUTC: ""
        ))
    }
    .padding()
    .frame(width: 340)
    .background(.ultraThickMaterial)
}
