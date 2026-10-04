import SwiftUI

/// NAS over SMB: enter host/share/credentials → browse folders → cache + play.
struct SMBBrowserView: View {
    @EnvironmentObject var smb: SMBService
    @EnvironmentObject var local: LocalLibraryService
    @EnvironmentObject var player: AudioPlayerManager

    @State private var host = ""
    @State private var share = "music"
    @State private var user = ""
    @State private var password = ""
    @State private var downloading: String? = nil

    var body: some View {
        List {
            if smb.connectedShare == nil {
                Section("Connect") {
                    TextField("Host (e.g. 192.168.1.10)", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Share (e.g. music)", text: $share)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username (optional)", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button(smb.isBusy ? "Connecting…" : "Connect") {
                        Task {
                            let ok = await smb.connect(
                                share: SMBShare(host: host.trimmingCharacters(in: .whitespaces),
                                                share: share.trimmingCharacters(in: .whitespaces),
                                                username: user.isEmpty ? nil : user),
                                password: password)
                            if ok { password = "" } // don't keep in UI state
                        }
                    }
                    .disabled(host.isEmpty || share.isEmpty || smb.isBusy)
                } footer: {
                    Text("Needs the AMSMB2 package (see SMBService.swift). Same Wi-Fi as NAS. Credentials stay in memory only.")
                }
            } else {
                Section("Connected: \(smb.connectedShare!.host)/\(smb.connectedShare!.share)") {
                    Button("Disconnect") { smb.disconnect() }
                }
                Section(smb.connectedShare?.path ?? "/") {
                    if smb.isBusy { ProgressView() }
                    ForEach(smb.files) { f in
                        HStack {
                            Image(systemName: f.isDirectory ? "folder.fill" : "music.note")
                            VStack(alignment: .leading) {
                                Text(f.name).lineLimit(1)
                                if !f.isDirectory {
                                    Text("\(f.size / 1024) KB").font(.caption).foregroundColor(.gray)
                                }
                            }
                            Spacer()
                            if !f.isDirectory && f.isAudio {
                                if downloading == f.id.uuidString {
                                    ProgressView()
                                } else {
                                    Button("Cache") {
                                        Task {
                                            downloading = f.id.uuidString
                                            defer { downloading = nil }
                                            do {
                                                let url = try await smb.downloadToCache(f, local: local)
                                                let t = Track(id: "smb-" + f.path, title: (f.name as NSString).deletingPathExtension,
                                                              artist: smb.connectedShare?.host ?? "NAS", album: smb.connectedShare?.share ?? "SMB",
                                                              duration: 0, artworkURL: nil, streamURL: url, source: .local)
                                                player.play(t)
                                            } catch {
                                                smb.lastError = error.localizedDescription
                                            }
                                        }
                                    }
                                    .font(.caption.bold())
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if f.isDirectory { Task { await smb.list(path: f.path) } }
                        }
                    }
                }
            }

            if let err = smb.lastError {
                Section { Text(err).foregroundColor(.orange).font(.caption) }
            }
        }
        .navigationTitle("NAS (SMB)")
    }
}
