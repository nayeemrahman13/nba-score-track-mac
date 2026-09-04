import SwiftUI

struct ContentView: View {
    @EnvironmentObject var nbaService: NBAService
    @State private var selectedTab = "Today"
    @State private var showingSettings = false
    
    private let tabs = ["Yesterday", "Today", "Tomorrow"]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            // Segmented Control
            tabPicker
            
            // Game List
            ScrollView {
                GameListView(games: gamesForSelectedTab, selectedDate: selectedTab)
            }
            .frame(height: 480)
            
            // Footer
            footerView
        }
        .frame(width: 340)
        .background(.ultraThickMaterial)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
    
    private var headerView: some View {
        HStack {
            Text("NBA Tracker")
                .font(.system(size: 13, weight: .semibold))
            
            Spacer()
            
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 16, height: 16)
                .opacity(nbaService.isLoading ? 1 : 0)
            
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
    
    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(tabs, id: \.self) { tab in
                Text(tab).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
    
    private var footerView: some View {
        HStack {
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 10))
                    Text("Quit")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private var gamesForSelectedTab: [Game] {
        let offset: Int
        switch selectedTab {
        case "Yesterday": offset = -1
        case "Tomorrow": offset = 1
        default: offset = 0
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let dateString = formatter.string(from: date)
        
        return nbaService.games[dateString] ?? []
    }
}

#Preview {
    ContentView()
        .environmentObject(NBAService())
}
