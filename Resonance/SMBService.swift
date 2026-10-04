import Foundation
import Combine

#if canImport(AMSMB2)
import AMSMB2
#endif

/// SMB client for NAS shares (Synology/QNAP/TrueNAS/Windows share).
/// SPM package AMSMB2 v4 (verified API: SMB2Manager, async connectShare/
/// contentsOfDirectory/contents): https://github.com/amosavian/AMSMB2
/// Pinned in CI via project.yml (`from: 4.0.0`).
/// NOTE (LGPL-2.1): AMSMB2 links libsmb2 — link dynamically for App Store
/// distribution (SPM does this by default).
///
/// MVP strategy: browse via SMB, download-to-cache, play via AVPlayer.
@MainActor
final class SMBService: ObservableObject {
    @Published private(set) var files: [SMBFile] = []
    @Published private(set) var isBusy = false
    @Published var lastError: String? = nil
    @Published var connectedShare: SMBShare? = nil

    #if canImport(AMSMB2)
    private var client: SMB2Manager?
    #endif

    func connect(share: SMBShare, password: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        #if canImport(AMSMB2)
        guard let url = URL(string: "smb://\(share.host)") else {
            lastError = "Invalid host: \(share.host)"
            return false
        }
        guard let manager = SMB2Manager(
            url: url,
            credential: URLCredential(user: share.username ?? "guest", password: password, persistence: .forSession)
        ) else {
            lastError = "Invalid SMB URL for host: \(share.host)"
            return false
        }
        do {
            try await manager.connectShare(name: share.share)
            self.client = manager
            self.connectedShare = share
            await list(path: share.path)
            return true
        } catch {
            lastError = "SMB connect failed (\(share.host)/\(share.share)): \(error.localizedDescription)"
            return false
        }
        #else
        lastError = "AMSMB2 package not added yet. Xcode → Add Package: https://github.com/amosavian/AMSMB2, then rebuild."
        return false
        #endif
    }

    func list(path: String) async {
        #if canImport(AMSMB2)
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            // Entries are [URLResourceKey: Any]; name lives in .nameKey (verified v4 API).
            let entries = try await client.contentsOfDirectory(atPath: path)
            self.files = entries.compactMap { dict in
                guard let name = dict[.nameKey] as? String,
                      name != ".", name != ".." else { return nil }
                let fullPath: String = {
                    if let p = dict[.pathKey] as? String, !p.isEmpty { return p }
                    return (path as NSString).appendingPathComponent(name)
                }()
                let isDir = (dict[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                    || fullPath.hasSuffix("/")
                let size: Int64 = (dict[.fileSizeKey] as? NSNumber)?.int64Value
                    ?? (dict[.fileSizeKey] as? Int64) ?? 0
                return SMBFile(name: name, path: fullPath, isDirectory: isDir, size: size)
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.lowercased() < $1.name.lowercased()
            }
            connectedShare?.path = path
        } catch {
            lastError = "List failed: \(error.localizedDescription)"
        }
        #else
        lastError = "Add AMSMB2 package to enable SMB browsing."
        #endif
    }

    /// Download an SMB file into Offline cache, return local URL.
    func downloadToCache(_ file: SMBFile, local: LocalLibraryService) async throws -> URL {
        #if canImport(AMSMB2)
        guard let client else { throw URLError(.notConnectedToInternet) }
        let dest = local.offlineURL.appendingPathComponent(file.name)
        let data: Data = try await client.contents(atPath: file.path)
        try data.write(to: dest, options: .atomic)
        local.refresh()
        return dest
        #else
        throw NSError(domain: "SMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Add AMSMB2 package first (see SMBService.swift header)."])
        #endif
    }

    func disconnect() {
        #if canImport(AMSMB2)
        client?.disconnectShare()
        client = nil
        #endif
        connectedShare = nil
        files = []
    }
}
