import SwiftUI

@MainActor
struct ContentArtworkView: View {
    @State private var model: ContentArtworkModel
    @State private var kind = ContentArtworkKind.poster
    @State private var operation: Task<Void,Never>?
    @Environment(\.dismiss) private var dismiss
    init(title: Title, context: SourceActionContext) {
        _model = State(initialValue:ContentArtworkModel(title:title,context:context))
    }
    var body: some View {
        NavigationStack {
            List {
                Text(model.title.name).font(.headline)
                Text("Choose from this title's delivered pictures. Your choice applies only to this profile; languages, sources and episode artwork remain unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.preference?.supported == true {
                    if let style = model.pictureStyle {
                        Text("Learn picture language and text style from the pictures you choose. Learning starts only after you enable it and needs three different titles per picture type. Your manual and standard choices take priority.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(style.enabled ? "Picture style learning: On" : "Picture style learning: Off") {
                            operation = Task { await model.updatePictureStyle(enabled: !style.enabled) }
                        }.disabled(model.busy)
                        Text("Poster choices: \(style.posterSamples); background choices: \(style.backdropSamples)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Forget learned picture style") {
                            operation = Task { await model.updatePictureStyle(enabled: nil, reset: true) }
                        }.disabled(model.busy)
                    }
                    Picker("Picture",selection:$kind) {
                        ForEach(ContentArtworkKind.allCases,id:\.self) { Text($0.label).tag($0) }
                    }
                    .disabled(model.busy)
                    ForEach(ContentArtworkWire.options(model.title,kind:kind)) { option in
                        Button {
                            let chosen = kind
                            operation = Task { await model.save(kind:chosen,url:option.url) }
                        } label: {
                            HStack(spacing:16) {
                                RemoteImage(url:Artwork.url(option.preview,size:"w342"),size:CGSize(width:80,height:70),contentMode:.fit) { _ in
                                    Image(systemName:"photo")
                                }
                                Text(option.label)
                                Spacer()
                                if model.preference?.choice(kind) == option.url { Image(systemName:"checkmark") }
                            }
                        }
                        .disabled(model.busy)
                    }
                }
                if model.busy { ProgressView() }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                if let message = model.pictureStyleMessage {
                    Text(message).foregroundStyle(.secondary)
                    if model.pictureStyle == nil, !model.busy {
                        Button("Reload picture learning") { operation = Task { await model.load() } }
                    }
                }
                if let confirmation = model.confirmation { Text(confirmation).foregroundStyle(.secondary) }
                if !model.busy, model.needsGalleryReload {
                    Button("Reload title pictures") { operation = Task { await model.reloadGallery() } }
                } else if !model.busy, model.preference == nil {
                    Button("Reload saved pictures") { operation = Task { await model.load() } }
                }
                Button("Done") { dismiss() }
            }
            .navigationTitle("Personal pictures")
        }
        .task { await model.load() }
        .onDisappear { model.close(); operation?.cancel() }
    }
}
