import SwiftUI

struct SearchView: View {
    @EnvironmentObject var local: LocalLibraryService
    @State private var query = ""

    var results: [Track] {
        guard !query.isEmpty else { return local.tracks }
        return local.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
            || $0.artist.localizedCaseInsensitiveContains(query)
            || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { t in TrackRow(track: t, context: results) }
                .navigationTitle("Search")
                .searchable(text: $query, prompt: "Songs on this iPhone")
                .overlay {
                    if results.isEmpty {
                        ContentUnavailableView("No results", systemImage: "magnifyingglass",
                            description: Text("NAS tracks are browsed in the NAS tab, not indexed here (MVP)."))
                    }
                }
        }
    }
}
