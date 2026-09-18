import SwiftUI

struct GameRowView: View {
    let game: Game
    @State private var isExpanded = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            if game.status == .upcoming {
                mainContent
            } else {
                Button { isExpanded.toggle() } label: { mainContent }
                    .buttonStyle(ScoreRowButtonStyle())
                    .focused($isFocused)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2))
                    .accessibilityLabel("\(game.awayTeam.tricode) at \(game.homeTeam.tricode), \(game.statusText)")
                    .accessibilityValue("\(game.awayTeam.score) to \(game.homeTeam.score), \(isExpanded ? "expanded" : "collapsed")")
                    .accessibilityHint("Show or hide player leaders")
            }
            
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

    }
    
    // MARK: - Main Content
    
    private var mainContent: some View {
        HStack(spacing: 12) {
            // Teams Column
            VStack(alignment: .leading, spacing: 4) {
                teamRow(game.awayTeam, isWinner: game.status == .finished && game.awayTeam.score > game.homeTeam.score)
                teamRow(game.homeTeam, isWinner: game.status == .finished && game.homeTeam.score > game.awayTeam.score)
            }
            
            Spacer()
            
            // Status Column
            VStack(alignment: .trailing, spacing: 4) {
                statusLabel
                if !game.broadcaster.isEmpty {
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
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
    
    private func teamRow(_ team: Team, isWinner: Bool) -> some View {
        HStack(spacing: 8) {
            AsyncImage(url: team.logoURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "basketball")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            
            Text(team.tricode)
                .font(.system(size: 13, weight: isWinner ? .bold : .medium))
                .frame(width: 36, alignment: .leading)
            
            if game.status != .upcoming {
                Text("\(team.score)")
                    .font(.system(size: 16, weight: isWinner ? .bold : .medium, design: .rounded))
                    .frame(minWidth: 32, alignment: .trailing)
                    .monospacedDigit()
                    .foregroundStyle(game.status == .live || isWinner ? .primary : .secondary)
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
            Text(game.statusText.isEmpty ? "Final" : game.statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        case .upcoming:
            Text(localStartTime)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
    
    private var localStartTime: String {
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: game.gameTimeUTC)
        if date == nil {
            formatter.formatOptions.insert(.withFractionalSeconds)
            date = formatter.date(from: game.gameTimeUTC)
        }
        // Preserve special NBA statuses such as postponed, rather than showing
        // the original tipoff time as though the game were still scheduled.
        let status = game.statusText.lowercased()
        if status.contains("postpon") || status.contains("cancel") || status.contains("tbd") { return game.statusText }
        return date?.formatted(date: .omitted, time: .shortened) ?? game.statusText
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

/// Native focus/keyboard semantics, with immediate pressed feedback. No repeated
/// expansion animation or score-counting animation in this glanceable utility.
private struct ScoreRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.07 : 0))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
    }
}
