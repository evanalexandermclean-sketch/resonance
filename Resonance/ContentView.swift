import SwiftUI

struct ContentView: View {
    @EnvironmentObject var player: AudioPlayerManager
    @State private var showPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                LibraryView()
                    .tabItem { Label("Your Library", systemImage: "books.vertical.fill") }
            }
            .tint(.spotifyGreen)

            if player.currentTrack != nil {
                MiniPlayer(showFull: $showPlayer)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 52) // above tab bar
            }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .environmentObject(player)
        }
        .background(Color.spotifyBackground.ignoresSafeArea())
    }
}

extension Color {
    static let spotifyGreen = Color(red: 0.11, green: 0.72, blue: 0.33) // #1DB954
    static let spotifyBackground = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let spotifyCard = Color(red: 0.13, green: 0.13, blue: 0.14)
}

func formatTime(_ s: TimeInterval) -> String {
    guard s.isFinite && s >= 0 else { return "0:00" }
    let m = Int(s) / 60
    let sec = Int(s) % 60
    return String(format: "%d:%02d", m, sec)
}
