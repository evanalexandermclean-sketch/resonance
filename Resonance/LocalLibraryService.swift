import Foundation
import AVFoundation
import Combine

/// Scans the app's Documents folder for audio imported via Files / fileImporter.
/// iOS cannot read the whole phone filesystem — this is the App Store-safe pattern
/// (same as VLC / foobar2000): import once, play forever offline.
final class LocalLibraryService: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published var isLoading = false

    private let docsURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    /// Downloads from NAS land here so they survive app restarts and play offline.
    var offlineURL: URL {
        let u = docsURL.appendingPathComponent("Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private let supportedExts = ["mp3", "m4a", "aac", "wav", "aiff", "caf", "mp4"]

    init() { refresh() }

    func refresh() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = self.scanDocuments()
            DispatchQueue.main.async {
                self.tracks = found
                self.isLoading = false
            }
        }
    }

    /// Copy security-scoped URLs from fileImporter into Documents.
    func importFiles(_ urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let dest = docsURL.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                print("Import failed \(url.lastPathComponent): \(error)")
            }
        }
        refresh()
    }

    func delete(_ track: Track) {
        guard track.isLocalFile else { return }
        try? FileManager.default.removeItem(at: track.streamURL)
        refresh()
    }

    /// Offline helpers used by DownloadManager + UI.
    func localFileURL(for track: Track) -> URL {
        offlineURL.appendingPathComponent(track.cacheFileName)
    }

    func isDownloaded(_ track: Track) -> Bool {
        FileManager.default.fileExists(atPath: localFileURL(for: track).path)
    }

    func downloadedTrack(for track: Track) -> Track? {
        let url = localFileURL(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var copy = track
        copy.streamURL = url
        copy.source = .local
        return copy
    }

    // MARK: - Private

    private func scanDocuments() -> [Track] {
        guard let enumerator = FileManager.default.enumerator(at: docsURL, includingPropertiesForKeys: nil) else { return [] }
        var out: [Track] = []
        for case let file as URL in enumerator {
            guard supportedExts.contains(file.pathExtension.lowercased()) else { continue }
            out.append(trackForFile(file))
        }
        return out.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    private func trackForFile(_ url: URL) -> Track {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Unknown Artist"
        var album = "Local Files"
        var duration: TimeInterval = 0

        // Synchronous metadata read is fine on background queue
        let group = DispatchGroup()
        group.enter()
        Task {
            do {
                let meta = try await asset.load(.commonMetadata)
                for item in meta {
                    guard let key = item.commonKey?.rawValue else { continue }
                    let val = try? await item.load(.stringValue)
                    if key == "title", let v = val, !v.isEmpty { title = v }
                    if key == "artist", let v = val, !v.isEmpty { artist = v }
                    if key == "albumName", let v = val, !v.isEmpty { album = v }
                }
                let d = try await asset.load(.duration)
                if d.seconds.isFinite { duration = d.seconds }
            } catch { print("metadata error: \(error)") }
            group.leave()
        }
        _ = group.wait(timeout: .now() + 4)

        return Track(
            id: "local-" + url.lastPathComponent,
            title: title, artist: artist, album: album,
            duration: duration,
            artworkURL: nil,
            streamURL: url,
            source: .local
        )
    }
}
