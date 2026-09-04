import SwiftUI

struct LeadersView: View {
    let teamName: String
    let leaders: [Player]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(teamName) Leaders")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            
            ForEach(leaders) { player in
                HStack(spacing: 8) {
                    Text(player.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    HStack(spacing: 10) {
                        statBadge(player.points, "PTS")
                        statBadge(player.rebounds, "REB")
                        statBadge(player.assists, "AST")
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.03))
        )
    }
    
    private func statBadge(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 28)
    }
}

#Preview {
    LeadersView(
        teamName: "LAL",
        leaders: [
            Player(name: "LeBron James", nameI: "L. James", position: "F", points: 28, rebounds: 8, assists: 11),
            Player(name: "Anthony Davis", nameI: "A. Davis", position: "C", points: 24, rebounds: 12, assists: 3)
        ]
    )
    .padding()
    .frame(width: 300)
    .background(.ultraThickMaterial)
}
