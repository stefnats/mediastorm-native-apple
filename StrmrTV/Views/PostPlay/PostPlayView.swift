import SwiftUI

@MainActor
struct PostPlayScene: View {
    let offer: PostPlayOffer
    let onClose: () -> Void
    let onPlay: (PlaybackRequest) -> Void
    @StateObject private var model: PostPlayModel
    @State private var detail: DetailsTarget?
    @State private var playTask: Task<Void, Never>?
    @FocusState private var closeFocused: Bool
    init(offer: PostPlayOffer, onClose: @escaping () -> Void, onPlay: @escaping (PlaybackRequest) -> Void) {
        self.offer = offer; self.onClose = onClose; self.onPlay = onPlay
        _model = StateObject(wrappedValue: PostPlayModel(offer: offer))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.heading).font(.title2.bold())
                            Text(model.title?.name ?? offer.request.title.name).font(.headline)
                        }
                        Spacer()
                        Button("Close", action: onClose).focused($closeFocused)
                    }
                    rating
                    suggestions
                }
                .padding(32)
                .frame(maxWidth: 1400, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationDestination(item: $detail) { target in
                if model.current {
#if os(iOS)
                    MobileDetailsView(target: target, automaticallyPrewarm: false)
#else
                    DetailsView(target: target, automaticallyPrewarm: false)
#endif
                } else { Text("The original profile changed. Close this view.") }
            }
            .task { model.load(); closeFocused = true }
#if os(tvOS)
            .onExitCommand(perform: onClose)
#endif
        }
        .onDisappear { model.close(); playTask?.cancel() }
    }
    @ViewBuilder private var rating: some View {
        if model.loading { ProgressView("Loading completed playback…") }
        if let error = model.error {
            Text(error).foregroundStyle(.secondary)
            if offer.completion != nil { Button("Reload completed title") { model.load() }.disabled(model.loading || model.saving || !model.current || !model.listSaving.isEmpty) }
        }
        if let value = model.rating {
            if model.question {
                Text(offer.request.title.isMovie ? "Did you enjoy this movie?" : "How do you like this series?").font(.title3)
                if !offer.request.title.isMovie { Text("Your rating is for the whole series.").font(.footnote) }
                HStack {
                    Button("Yes") { model.rate(.like) }
                    Button("No") { model.rate(.dislike) }
                    Button("Skip") { model.skip() }
                    Button("More choices") { model.expanded = true }
                }.disabled(model.loading || model.saving || !model.current || !model.listSaving.isEmpty)
                if model.expanded {
                    HStack {
                        Button("Love it") { model.rate(.love) }
                        Button("Clear rating") { model.rate(.none) }
                    }.disabled(model.loading || model.saving || !model.current || !model.listSaving.isEmpty)
                }
            } else {
                HStack { Text("Your rating: \(value.label)"); Button("Change rating") { model.edit() } }
                    .disabled(model.loading || model.saving || !model.current || !model.listSaving.isEmpty)
            }
        }
        if model.saving { ProgressView("Saving your rating…") }
        if let future = offer.request.postPlayStamp?.upcoming, let date = future.airedDate, ReleaseBadge.forEpisode(airDate: date) != nil {
            Text("New episode on \(date)").font(.callout)
            Button("Remind Me…") {
                guard let subject = model.reminder() else { return }
                ReminderPresentation.show(subject, context: offer.context)
            }.disabled(!model.current || model.saving)
        }
    }
    @ViewBuilder private var suggestions: some View {
        Text("More for you").font(.title3.bold())
        if model.suggestionsSource == "saved_choices" { Text("From your saved choices").font(.footnote) }
        if model.suggestionsLoading { ProgressView("Loading suggestions…") }
        if let error = model.suggestionsError {
            Text(error).foregroundStyle(.secondary)
            Button("Retry suggestions") { model.load() }.disabled(model.loading || model.saving || !model.current || !model.listSaving.isEmpty)
        }
        if let error = model.listError { Text(error).foregroundStyle(.secondary) }
        if model.title != nil && !model.loading && !model.suggestionsLoading && model.suggestions.isEmpty && model.suggestionsError == nil {
            Text("No suggestions are available right now.")
        }
        ForEach(model.suggestions) { row in
            VStack(alignment: .leading, spacing: 10) {
                Text(row.title.name).font(.headline)
                HStack {
                    Button(model.saved.contains(row.id) ? "Saved" : model.uncertainSaves.contains(row.id) ? "Check save status" : "My List") { model.save(row) }
                        .disabled(model.saved.contains(row.id) || model.listSaving.contains(row.id))
                    Button("Details") { detail = model.details(row) }
                    Button("Play") {
                        guard playTask == nil else { return }
                        playTask = Task {
                            defer { playTask = nil }
                            do {
                                let request = try await model.preparePlay(row)
                                try Task.checkCancellation(); guard model.current else { return }; onPlay(request)
                            } catch { model.playbackFailed(error) }
                        }
                    }.disabled(playTask != nil)
                }
                .disabled(model.loading || model.saving || !model.current)
            }
            .padding(.vertical, 12)
        }
    }
}
