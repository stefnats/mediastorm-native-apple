import SwiftUI

/// Both platforms use the same saved-file vocabulary. These controls do not
/// search, probe or infer spoken language from release names.
struct StoredMediaFilterControls: View {
    let list: BrowseList
    let capability: StoredMediaCapability
    @Binding var options: BrowseOptions
    @State private var languageCode = ""
    @State private var languageError = false
    var body: some View {
        Form {
            Section("Original title language") {
                Text("Original metadata language, independent of an audio track.").font(.footnote)
                ForEach(Array(options.originalLanguages).sorted(), id: \.self) { code in
                    Button("Remove \(MediaFilterValues.label(code))") { options.originalLanguages.remove(code) }
                }
                Picker("Add language", selection: Binding(get: { "" }, set: { if !$0.isEmpty { options.originalLanguages.insert($0) } })) {
                    Text("Choose…").tag("")
                    ForEach(MediaFilterValues.languages, id: \.self) { Text(MediaFilterValues.label($0)).tag($0) }
                }
                TextField("Registered language code", text: $languageCode)
                    .autocorrectionDisabled()
                Button("Add code") {
                    if let code = MediaFilterValues.language(languageCode), options.originalLanguages.count < 32 {
                        options.originalLanguages.insert(code); languageCode = ""; languageError = false
                    } else { languageError = true }
                }
                if languageError { Text("Enter a registered ISO language code; at most 32 languages.").foregroundStyle(.red) }
                Toggle("Include unknown original language", isOn: $options.includeUnknownOriginalLanguage)
            }
            .disabled(!capability.originalLanguage)
            Section("Saved file and track facts") {
                Text("The server matches all criteria within one stored file and its tracks. Unknown facts are handled explicitly.").font(.footnote)
                stringPicker("Audio language", value: $options.storedMedia.audioLanguage, values: MediaFilterValues.languages, language: true)
                stringPicker("Subtitle language", value: $options.storedMedia.subtitleLanguage, values: MediaFilterValues.languages, language: true)
                stringPicker("Audio codec", value: $options.storedMedia.audioCodec, values: MediaFilterValues.audioCodecs)
                stringPicker("Video codec", value: $options.storedMedia.videoCodec, values: MediaFilterValues.videoCodecs)
                stringPicker("Dynamic range", value: $options.storedMedia.hdr, values: MediaFilterValues.ranges)
                Picker("Minimum stored height", selection: $options.storedMedia.minHeight) {
                    Text("Any").tag(Int?.none)
                    ForEach(MediaFilterValues.heights, id: \.self) { Text("\($0)p").tag(Optional($0)) }
                }
                stringPicker("Subtitles", value: $options.storedMedia.subtitles, values: ["present", "absent"])
                Picker("Unknown file facts", selection: $options.storedMedia.unknown) {
                    Text("Include unknown").tag("include")
                    Text("Exclude unknown").tag("exclude")
                    Text("Only unknown").tag("only")
                }
            }
            .disabled(!capability.media)
            if !capability.media { Text("This server or catalogue does not confirm saved media filter support.") }
            if !capability.originalLanguage { Text("Original-language filtering is unavailable for this catalogue.") }
            Section("List order") {
                Picker("Sort", selection: $options.sort) {
                    ForEach(list.savedSorts, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Ascending", isOn: $options.ascending)
                Picker("Type", selection: $options.kind) {
                    Text("Movies and Shows").tag(BrowseKind?.none)
                    ForEach(BrowseKind.allCases) { Text($0.noun).tag(Optional($0)) }
                }
            }
            Button("Clear saved filters", role: .destructive) {
                options.originalLanguages = []; options.includeUnknownOriginalLanguage = false; options.storedMedia = StoredMediaFilters()
            }
        }
    }
    private func stringPicker(_ title: LocalizedStringKey, value: Binding<String?>, values: [String], language: Bool = false) -> some View {
        Picker(title, selection: value) {
            Text("Any").tag(String?.none)
            ForEach(Array(Set(values + [value.wrappedValue].compactMap { $0 } )).sorted(), id: \.self) { code in
                Text(language ? MediaFilterValues.label(code) : code).tag(Optional(code))
            }
        }
    }
}

struct StoredMediaFilterEntry: View {
    let list: BrowseList
    var options = BrowseOptions()
    var body: some View {
        if list.storedEligible {
            NavigationLink { StoredMediaCatalogueView(list: list, options: options) } label: {
                Label("Filter saved catalogue", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

/// A shared, finite catalogue leaf. Cached views never fall back to discovery;
/// ordinary list management stays available in the unchanged parent view.
struct StoredMediaCatalogueView: View {
    @StateObject private var model: StoredMediaBrowseModel
    @State private var controls = false
    @State private var width: CGFloat = 0
    init(list: BrowseList, options: BrowseOptions = BrowseOptions()) {
        _model = StateObject(wrappedValue: StoredMediaBrowseModel(list: list, options: options))
    }
    var body: some View {
        Group {
#if os(iOS)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    actions
                    Text("\(model.total ?? 0) saved matches").font(.footnote).foregroundStyle(.secondary)
                    MobilePosterGrid(items: model.rows, onNearEnd: { model.loadMore() }) { row in
                        VStack {
                            MobileGridCard(card: row.card)
                            if row.hidden != nil { Button("Unhide") { model.unhide(row) }.disabled(model.loading || !model.current) }
                        }
                    }
                    status
                }.padding()
            }
            .navigationTitle(model.list.title)
#else
            GridPage(title: model.list.title, gridWidth: $width) {
                actions
                Text("\(model.total ?? 0) saved matches").font(.callout).foregroundStyle(.secondary)
                CardGrid(items: model.rows, cardWidth: PosterCard.width, available: width, onNearEnd: { model.loadMore() }) { row, cardWidth in
                    VStack {
                        if row.watching != nil { LandscapeCard(card: row.card, width: cardWidth) }
                        else {
                            switch row.entry {
                            case let .title(title): PosterCard(title: title, width: cardWidth)
                            case let .item(item): PosterCard(item: item, width: cardWidth)
                            case let .library(entry): LibraryPosterCard(entry: entry, width: cardWidth)
                            }
                        }
                        if row.hidden != nil { Button("Unhide") { model.unhide(row) }.disabled(model.loading || !model.current) }
                    }
                }
                status
            }
#endif
        }
        .sheet(isPresented: $controls) {
            NavigationStack {
                StoredMediaFilterControls(list: model.list, capability: model.capability, options: $model.draft)
                    .navigationTitle("Saved filters")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Apply") { controls = false; model.apply() } }
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.draft = model.applied; controls = false } }
                    }
            }
        }
        .task { model.reopen(); model.appear() }
        .onDisappear { if !controls { model.close() } }
#if os(iOS)
        .navigationDestination(for: DetailsTarget.self) { MobileDetailsView(target: $0) }
#else
        .navigationDestination(for: DetailsTarget.self) { DetailsView(target: $0) }
#endif
    }
    private var actions: some View {
        HStack {
            Button { controls = true } label: { Label("Saved filters", systemImage: "line.3.horizontal.decrease.circle") }
            Button("Refresh saved view") { model.refresh() }.disabled(model.loading)
        }
    }
    @ViewBuilder private var status: some View {
        if let error = model.error { Text(error).foregroundStyle(.red) }
        if model.loading { ProgressView() }
        else if model.total == 0 { Text("No titles match these filters.") }
        else if !model.retired && model.hasMore { Button("Load more") { model.loadMore() } }
    }
}
