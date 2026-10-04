import SwiftUI

/// Spotify-like home: greeting, quick picks, recently played, NAS shortcut.
struct HomeView: View {
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var local: LocalLibraryService
    @EnvironmentObject var dlna: DLNAService

    private var allTracks: [Track] {
        local.tracks // DLNA tracks are browsed on demand, not merged
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(greeting())
                        .font(.largeTitle.bold())
                        .padding(.horizontal)

                    // Quick grid (first 6 local tracks)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(allTracks.prefix(6)) { t in
                            Button { player.play(t, in: allTracks) } label: {
                                HStack {
                                    Image(systemName: t.source == .local ? "iphone" : "network")
                                        .frame(width: 48, height: 48)
                                        .background(Color.spotifyCard)
                                    Text(t.title).lineLimit(2).font(.subheadline.bold())
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }
                                .background(Color.spotifyCard)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)

                    // NAS status card
                    NavigationLink(destination: DLNABrowserView()) {
                        HStack {
                            Image(systemName: "network")
                                .font(.title2)
                            VStack(alignment: .leading) {
                                Text(dlna.servers.isEmpty ? "Connect your NAS" : "\(dlna.servers.count) NAS found")
                                    .bold()
                                Text(dlna.servers.isEmpty ? "Tap to scan for DLNA servers" : (dlna.servers.first?.friendlyName ?? ""))
                                    .font(.caption).foregroundColor(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .background(Color.spotifyCard)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)

                    // All songs
                    HStack {
                        Text("Your songs").font(.title2.bold())
                        Spacer()
                        Button("Play all") {
                            player.play(queue: allTracks)
                        }.font(.subheadline.bold()).foregroundColor(.spotifyGreen)
                    }
                    .padding(.horizontal)

                    ForEach(allTracks.prefix(20)) { t in
                        TrackRow(track: t, context: allTracks)
                    }
                }
                .padding(.vertical)
            }
            .background(Color.spotifyBackground)
            .navigationTitle("Good \(daypart())")
            .toolbar {
                Button { local.refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
    }

    private func greeting() -> String { "Good \(daypart())" }
    private func daypart() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "morning" }
        if h < 18 { return "afternoon" }
        return "evening"
    }
}

struct TrackRow: View {
    @EnvironmentObject var player: AudioPlayerManager
    let track: Track
    let context: [Track]

    var body: some View {
        Button { player.play(track, in: context) } label: {
            HStack {
                AsyncArtwork(url: track.artworkURL, fallback: track.source == .local ? "iphone" : "network")
                VStack(alignment: .leading) {
                    Text(track.title).lineLimit(1).font(.body)
                    Text("\(track.artist) • \(track.album)").lineLimit(1).font(.caption).foregroundColor(.gray)
                }
                Spacer()
                if player.currentTrack == track {
                    Image(systemName: "chart.bar.fill").foregroundColor(.spotifyGreen)
                        .symbolEffect(.variableColor.iterative)
                }
                Text(formatTime(track.duration)).font(.caption).foregroundColor(.gray)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct AsyncArtwork: View {
    let url: URL?
    let fallback: String
    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { img in img.resizable() } placeholder: {
                    Image(systemName: "music.note").frame(width: 48, height: 48)
                }
            } else {
                Image(systemName: "music.note")
                    .frame(width: 48, height: 48)
                    .background(Color.spotifyCard)
            }
        }
        .frame(width: 48, height: 48)
        .cornerRadius(4)
    }
}
