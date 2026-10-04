import SwiftUI

@main
struct ResonanceApp: App {
    @StateObject private var player = AudioPlayerManager.shared
    @StateObject private var localLibrary = LocalLibraryService()
    @StateObject private var dlna = DLNAService()
    @StateObject private var downloads = DownloadManager()
    @StateObject private var smb = SMBService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(localLibrary)
                .environmentObject(dlna)
                .environmentObject(downloads)
                .environmentObject(smb)
                .preferredColorScheme(.dark)
        }
    }
}
