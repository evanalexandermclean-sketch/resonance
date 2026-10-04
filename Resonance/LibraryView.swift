import SwiftUI
import UniformTypeIdentifiers

/// Your Library: source filter + local import + playlists (in-memory MVP).
struct LibraryView: View {
    @EnvironmentObject var local: LocalLibraryService
    @EnvironmentObject var player: AudioPlayerManager
    @State private var filter: MusicSource? = nil // nil = all
    @State private var showImporter = false
    @State private var playlists: [Playlist] = [
        Playlist(name: "Liked Songs", tracks: [], coverSymbol: "heart.fill")
    ]

    var visibleLocal: [Track] {
        guard filter == nil || filter == .local else { return [] }
        return local.tracks
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Sources") {
                    NavigationLink(destination: DLNABrowserView()) {
                        Label("NAS (DLNA)", systemImage: "network")
                    }
                    NavigationLink(destination: SMBBrowserView()) {
                        Label("NAS (SMB share)", systemImage: "externaldrive.connected.to.line.below.fill")
                    }
                    HStack {
                        Label("This iPhone", systemImage: "iphone")
                        Spacer()
                        Text("\(local.tracks.count)").foregroundColor(.gray)
                    }
                    Button { showImporter = true } label: {
                        Label("Import audio files", systemImage: "square.and.arrow.down")
                    }
                }

                Section("Playlists") {
                    ForEach(playlists) { p in
                        NavigationLink(destination: PlaylistDetailView(playlist: p)) {
                            Label("\(p.name) (\(p.tracks.count))", systemImage: p.coverSymbol)
                        }
                    }
                }

                if !visibleLocal.isEmpty {
                    Section("On this iPhone") {
                        ForEach(visibleLocal) { t in
                            TrackRow(track: t, context: visibleLocal)
                                .swipeActions {
                                    Button(role: .destructive) { local.delete(t) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Your Library")
            .toolbar {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(nil as MusicSource?)
                    Text("Phone").tag(MusicSource.local as MusicSource?)
                    Text("NAS").tag(MusicSource.dlna as MusicSource?)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { local.importFiles(urls) }
            }
        }
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject var player: AudioPlayerManager
    let playlist: Playlist
    var body: some View {
        List {
            if playlist.tracks.isEmpty {
                Text("Nothing here yet. Play songs and add them to playlists in the next iteration.")
                    .foregroundColor(.gray)
            } else {
                ForEach(playlist.tracks) { t in TrackRow(track: t, context: playlist.tracks) }
                Button("Play") { player.play(queue: playlist.tracks) }
                    .foregroundColor(.spotifyGreen).bold()
            }
        }
        .navigationTitle(playlist.name)
    }
}
