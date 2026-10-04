import SwiftUI

/// Collapsed Spotify-style bar above the tab bar.
struct MiniPlayer: View {
    @EnvironmentObject var player: AudioPlayerManager
    @Binding var showFull: Bool

    var body: some View {
        if let t = player.currentTrack {
            Button { showFull = true } label: {
                HStack {
                    AsyncArtwork(url: t.artworkURL, fallback: "music.note")
                    VStack(alignment: .leading) {
                        Text(t.title).lineLimit(1).font(.subheadline.bold())
                        Text(t.artist).lineLimit(1).font(.caption).foregroundColor(.gray)
                    }
                    Spacer()
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                        .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.spotifyCard)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Full-screen player: artwork, slider, controls, queue.
struct PlayerView: View {
    @EnvironmentObject var player: AudioPlayerManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let t = player.currentTrack {
                    AsyncImage(url: t.artworkURL) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "music.note")
                            .font(.system(size: 100))
                            .frame(width: 280, height: 280)
                            .background(Color.spotifyCard)
                    }
                    .frame(width: 280, height: 280)
                    .cornerRadius(12)

                    VStack(spacing: 4) {
                        Text(t.title).font(.title2.bold()).multilineTextAlignment(.center)
                        Text("\(t.artist) • \(t.album)")
                            .foregroundColor(.gray)
                        Text(t.source.rawValue).font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.spotifyCard).cornerRadius(8)
                    }

                    VStack {
                        Slider(value: Binding(
                            get: { player.progress },
                            set: { player.seek(fraction: $0) }
                        ))
                        .tint(.spotifyGreen)
                        HStack {
                            Text(formatTime(player.elapsed)).font(.caption).foregroundColor(.gray)
                            Spacer()
                            Text(formatTime(player.duration)).font(.caption).foregroundColor(.gray)
                        }
                    }
                    .padding(.horizontal)

                    HStack(spacing: 40) {
                        Button { player.previous() } label: { Image(systemName: "backward.fill").font(.largeTitle) }
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 64)).foregroundColor(.spotifyGreen)
                        }
                        Button { player.next() } label: { Image(systemName: "forward.fill").font(.largeTitle) }
                    }

                    // Up next
                    if let idx = player.currentIndex, idx + 1 < player.queue.count {
                        List(player.queue[(idx+1)...].prefix(5), id: \.id) { t in
                            TrackRow(track: t, context: player.queue)
                        }
                        .listStyle(.plain)
                        .frame(maxHeight: 200)
                    }
                    Spacer()
                } else {
                    Text("Nothing playing")
                }
            }
            .padding()
            .background(Color.spotifyBackground)
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
