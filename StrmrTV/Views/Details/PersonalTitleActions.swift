import SwiftUI

/// A stable, named details entry shared by TV and phone. Its model captures the
/// current request context before any asynchronous rating read or save.
@MainActor
struct PersonalTitleActions: View {
    let title: Title
    @State private var ratingContext: RatingPresentation?
    @State private var artworkContext: RatingPresentation?
    private struct RatingPresentation: Identifiable {
        let id = UUID()
        let context: SourceActionContext
    }
    var body: some View {
        HStack {
            Button {
                ratingContext = RatingPresentation(context: APIClient.shared.sourceContext())
            } label: {
                Label("Personal rating…", systemImage: "heart.circle")
            }
            .accessibilityIdentifier("personal-title.rating")
            Button {
                artworkContext = RatingPresentation(context: APIClient.shared.sourceContext())
            } label: {
                Label("Personal pictures…", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("personal-title.artwork")
        }
        .sheet(item: $ratingContext) { presentation in
            PersonalRatingSheet(title: title, context: presentation.context)
        }
        .sheet(item: $artworkContext) { presentation in
            ContentArtworkView(title:title,context:presentation.context)
        }
    }
}

@MainActor
private struct PersonalRatingSheet: View {
    @StateObject private var model: TitleRatingModel
    @State private var saving: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    init(title: Title, context: SourceActionContext) {
        _model = StateObject(wrappedValue: TitleRatingModel(target: DetailsTarget(title), context: context))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.target.name).font(.headline)
                    Text("Your preference helps this profile's recommendations. It does not mark the title watched or change external ratings.")
                        .font(.caption)
                }
                if model.rating != nil {
                    Picker("Your rating", selection: $model.selected) {
                        ForEach(PersonalTitleRating.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Button("Save personal rating") { saving = Task { await model.save() } }
                        .disabled(model.busy)
                }
                if model.busy { ProgressView() }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                if !model.busy, model.rating == nil {
                    Button("Reload personal rating") { saving = Task { await model.load() } }
                }
                Button("Cancel", role: .cancel) { dismiss() }
            }
            .navigationTitle("Personal rating")
        }
        .task { await model.load() }
        .onChange(of: model.saved) { _, saved in if saved { dismiss() } }
        .onDisappear { model.close(); saving?.cancel() }
    }
}
