import Foundation
import Combine

/// Downloads DLNA/SMB streams into Documents/Offline so they play without NAS.
/// Uses the built-in async URLSession API (iOS 15+) — no custom delegate.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var inProgress: Set<String> = [] // track.id
    @Published private(set) var downloadedIDs: Set<String> = []
    @Published var lastError: String? = nil

    func isDownloaded(_ track: Track, local: LocalLibraryService) -> Bool {
        local.isDownloaded(track) || downloadedIDs.contains(track.id)
    }

    /// Download and return the local file URL. Refreshes the local library after.
    @discardableResult
    func download(_ track: Track, local: LocalLibraryService) async throws -> URL {
        if local.isDownloaded(track) { return local.localFileURL(for: track) }
        inProgress.insert(track.id)
        defer { inProgress.remove(track.id) }
        do {
            let dest = local.localFileURL(for: track)
            let (tmpURL, response) = try await URLSession.shared.download(from: track.streamURL)
            guard (response as? HTTPURLResponse)?.statusCode.map({ (200..<300).contains($0) }) ?? true else {
                throw URLError(.badServerResponse)
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            downloadedIDs.insert(track.id)
            local.refresh()
            return dest
        } catch {
            lastError = "Download failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// Play offline copy if present, else stream — Spotify-like seamless fallback.
    func play(_ track: Track, in context: [Track], player: AudioPlayerManager, local: LocalLibraryService) {
        let resolved = context.map { local.downloadedTrack(for: $0) ?? $0 }
        let current = local.downloadedTrack(for: track) ?? track
        player.play(current, in: resolved)
    }
}
