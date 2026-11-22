import SwiftUI

/// The title action captures its viewer and exact official episode on the tap,
/// rather than consulting a later selection while the lobby is open.
struct WatchTogetherButton: View {
    let title: DetailsTarget
    let episode: Episode?
    @State private var entry: Entry?
    @State private var error: String?
    private struct Entry: Identifiable {
        let id = UUID()
        let context: SourceActionContext
        let target: WatchRoomTarget
    }
    var body: some View {
        Button {
            do {
                let target = try WatchRoomTarget(title:title,episode:episode.map(DetailsRequest.episodeInfo))
                entry = Entry(context:APIClient.shared.sourceContext(),target:target)
            } catch { self.error = error.localizedDescription }
        } label: { Label("Watch Together",systemImage:"person.2").labelStyle(.iconOnly) }
        .disabled(!title.hasCatalogIDs || (!title.isMovie && episode == nil))
        .sheet(item:$entry) { item in WatchRoomsView(context:item.context,target:item.target) }
        .alert("Watch Together",isPresented:Binding(get:{ error != nil },set:{ if !$0 { error = nil } })) {
            Button("OK",role:.cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
