import SwiftUI

@main
struct NBAScoreTrackerApp: App {
    @StateObject private var nbaService = NBAService()
    
    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(nbaService)
                .onAppear {
                    nbaService.setPopoverVisible(true)
                }
                .onDisappear {
                    nbaService.setPopoverVisible(false)
                }
        } label: {
            Image(systemName: "basketball.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}
