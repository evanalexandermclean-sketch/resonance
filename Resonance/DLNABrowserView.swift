import SwiftUI

/// DLNA browser: discover -> pick server -> drill into containers -> play tracks.
struct DLNABrowserView: View {
    @EnvironmentObject var dlna: DLNAService
    @EnvironmentObject var player: AudioPlayerManager
    @State private var manualURL = ""
    @State private var showManual = false

    var body: some View {
        List {
            Section {
                Button(dlna.isSearching ? "Searching…" : "Scan for NAS (DLNA)") {
                    dlna.discover()
                }
                .disabled(dlna.isSearching)
                Button("Add NAS manually") { showManual = true }
            } footer: {
                Text("Phone and NAS must be on the same Wi-Fi. Enable Media Server / DLNA on Synology, QNAP, Plex, Jellyfin or MiniDLNA.")
            }

            if let err = dlna.lastError {
                Section { Text(err).foregroundColor(.orange).font(.caption) }
            }

            Section("Servers (\(dlna.servers.count))") {
                ForEach(dlna.servers) { s in
                    NavigationLink(destination: DLNAFolderView(server: s, objectID: "0", title: s.friendlyName)) {
                        VStack(alignment: .leading) {
                            Text(s.friendlyName).bold()
                            Text(s.locationURL.host ?? "").font(.caption).foregroundColor(.gray)
                        }
                    }
                }
            }
        }
        .navigationTitle("NAS (DLNA)")
        .alert("Add NAS manually", isPresented: $showManual) {
            TextField("http://192.168.1.10:50001/desc.xml", text: $manualURL)
                .textInputAutocapitalization(.never)
            Button("Add") { dlna.addManualServer(location: manualURL); manualURL = "" }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { if dlna.servers.isEmpty { dlna.discover() } }
    }
}

struct DLNAFolderView: View {
    @EnvironmentObject var dlna: DLNAService
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var local: LocalLibraryService
    @EnvironmentObject var downloads: DownloadManager
    let server: DLNAServer
    let objectID: String
    let title: String

    @State private var containers: [DLNAContainer] = []
    @State private var tracks: [Track] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading { ProgressView("Browsing NAS…") }
            ForEach(containers) { c in
                NavigationLink(destination: DLNAFolderView(server: server, objectID: c.id, title: c.title)) {
                    Label("\(c.title) (\(c.childCount))", systemImage: "folder.fill")
                }
            }
            if !tracks.isEmpty {
                Section("Tracks") {
                    Button("Play all") { player.play(queue: tracks) }
                        .foregroundColor(.spotifyGreen).bold()
                    ForEach(tracks) { t in
                        HStack {
                            TrackRow(track: local.downloadedTrack(for: t) ?? t, context: tracks)
                            Spacer()
                            if downloads.inProgress.contains(t.id) {
                                ProgressView()
                            } else if local.isDownloaded(t) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.spotifyGreen)
                            } else {
                                Button {
                                    Task { try? await downloads.download(t, local: local) }
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        let res = await dlna.browse(server: server, objectID: objectID)
        containers = res.containers
        tracks = res.tracks
        loading = false
    }
}
