import Foundation

enum MusicSource: String, Codable, CaseIterable {
    case local = "This iPhone"
    case dlna = "NAS (DLNA)"
    case smb = "NAS (SMB)"
}

struct Track: Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var artworkURL: URL?
    var streamURL: URL
    var source: MusicSource

    // Local file convenience
    var isLocalFile: Bool { streamURL.isFileURL }

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Playlist: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var tracks: [Track]
    var coverSymbol: String = "music.note.list"
}

struct DLNAServer: Identifiable, Hashable {
    let id: String // USN
    var friendlyName: String
    var locationURL: URL // device description XML
    var controlURL: URL? // ContentDirectory control URL (resolved after fetch)
    var manufacturer: String = ""

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DLNAServer, rhs: DLNAServer) -> Bool { lhs.id == rhs.id }
}

struct DLNAContainer: Identifiable, Hashable {
    let id: String
    var title: String
    var childCount: Int
}

struct SMBShare: Identifiable, Hashable {
    let id = UUID()
    var host: String
    var share: String
    var username: String?
    // password is kept in memory only, never logged
    var path: String = "/"
}

struct SMBFile: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64 = 0

    var isAudio: Bool {
        ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "opus", "mp4"]
            .contains((name as NSString).pathExtension.lowercased())
    }
}

extension Track {
    /// Stable filename for offline cache, safe for filesystem.
    var cacheFileName: String {
        let base = "\(artist)-\(title)".prefix(80)
        let safe = base.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        let ext = streamURL.pathExtension.isEmpty ? "mp3" : streamURL.pathExtension
        return "\(safe)-\(abs(id.hashValue)).\(ext)"
    }
}
