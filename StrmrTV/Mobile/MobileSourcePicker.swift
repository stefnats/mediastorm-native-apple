#if os(iOS)
import SwiftUI

/// Choose Source as a sheet: the title's library copies, then the indexer / scraper results in
/// the server's order with their health (pending checks long-polled), as the TV's
/// `SourcePickerView`. Tap plays a source; its menu (long press, or the row's swipe) opens
/// Audio & Subtitles to probe it and pick tracks first. Searches through the shared
/// `SourceSearch`, so the player's Switch Source shows the same list.
struct MobileSourcePicker: View {
    let title: DetailsTarget
    let episode: Episode?
    let heading: String
    var libraryVersions: [LibraryVersion] = []
    let contentPreference: ContentPreference?
    var onPickLibrary: (LibraryVersion) -> Void = { _ in }
    let onPick: (SourceResult, ManualTrackPick?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var filter: SourceFilterModel
    @State private var filterControls = false
    private var results: [SourceResult] { filter.rows.map(\.result) }
    private var isLoading: Bool { filter.loading }
    private var error: String? { filter.error }
    private var health: [Int: SourceHealth] { filter.health }
    @State private var trackPreferences = ManualTrackPreferences()
    @State private var trackOverrides: [Int: ManualTrackOverrides] = [:]
    @State private var probes: [Int: SourceTrackProbe] = [:]
    @State private var tracksTarget: TracksTarget?

    init(title: DetailsTarget, episode: Episode?, heading: String, libraryVersions: [LibraryVersion] = [], contentPreference: ContentPreference?, onPickLibrary: @escaping (LibraryVersion) -> Void = { _ in }, onPick: @escaping (SourceResult, ManualTrackPick?) -> Void) {
        self.title = title; self.episode = episode; self.heading = heading; self.libraryVersions = libraryVersions
        self.contentPreference = contentPreference; self.onPickLibrary = onPickLibrary; self.onPick = onPick
        _filter = StateObject(wrappedValue: SourceFilterModel(title: title, episode: episode))
    }

    struct TracksTarget: Identifiable, Hashable {
        let result: SourceResult
        var id: Int { result.index }
        static func == (a: Self, b: Self) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { SourceFilterStatus(model: filter, controls: $filterControls) }
                if !libraryVersions.isEmpty {
                    Section(libraryVersions.count == 1 ? String(localized: "In your libraries")
                                                       : String(localized: "\(libraryVersions.count) in your libraries")) {
                        ForEach(libraryVersions) { version in
                            Button {
                                guard filter.permitsLibrary else { return }
                                filter.close(); dismiss()
                                onPickLibrary(version)
                            } label: {
                                LibraryVersionRow(version: version)
                            }
                            .tint(.primary)
                        }
                    }
                }
                streams
            }
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { filter.close(); dismiss() } }
            }
            .navigationDestination(item: $tracksTarget) { target in tracksPage(target.result) }
        }
        .task { await load() }
        .onDisappear { if tracksTarget == nil && !filterControls { filter.close() } }
        .onChange(of: filter.page?.viewId) { probes = [:]; trackOverrides = [:] }
        .onChange(of: filter.latestEvidence) { before, after in
            for (index, evidence) in after where before[index]?.sourceVersion != evidence.sourceVersion { trackOverrides[index] = nil }
        }
    }

    @ViewBuilder
    private var streams: some View {
        Section {
            if isLoading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(filter.supported ? "Reading saved source view…" : "Searching sources…").foregroundStyle(.secondary)
                }
            } else if let error {
                ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if results.isEmpty {
                ContentUnavailableView("No Sources Found", systemImage: "magnifyingglass")
            } else {
                ForEach(filter.rows) { row in
                    let result = row.result
                    Button {
                        choose(row)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                                SourceRow(result: result, health: health[result.index], hasTrackPicks: !(trackOverrides[result.index]?.isEmpty ?? true))
                                if filter.supported { Text(SourceFilterLabels.verdict(row.verdict, basis: filter.page?.filters.basis ?? "candidate")).font(.footnote).foregroundStyle(.secondary) }
                            }
                    }
                    .tint(.primary)
                    .contextMenu {
                        Button {
                            choose(row)
                        } label: { Label("Play", systemImage: "play.fill") }
                        Button { showTracks(row) } label: { Label("Audio & Subtitles…", systemImage: "waveform") }
                    }
                    .swipeActions(edge: .trailing) {
                        Button { showTracks(row) } label: { Label("Tracks", systemImage: "waveform") }
                            .tint(.indigo)
                    }
                }
            }
        } header: {
            if !libraryVersions.isEmpty || (!isLoading && !results.isEmpty) {
                Text(results.isEmpty ? String(localized: "Streams")
                                     : results.count == 1 ? String(localized: "1 source")
                                                          : String(localized: "\(results.count) sources"))
            }
        }
    }

    private func tracksPage(_ result: SourceResult) -> some View {
        let index = result.index
        let close = dismiss
        return MobileTracksView(
            model: SourceTracksModel(result: result, cached: probes[index]) { probe in record(probe, for: result) },
            defaults: nil, preferences: trackPreferences,
            overrides: Binding(get: { trackOverrides[index] ?? ManualTrackOverrides() },
                               set: { trackOverrides[index] = $0 }),
            playLabel: String(localized: "Play"), inSheet: false
        ) { pick in
            guard let selected = filter.takeManual(result) else { return }
            filter.close(); close()
            onPick(selected, pick)
        }
    }

    // MARK: Tracks

    private func showTracks(_ row: SourceFilterRow) {
        guard let result = filter.beginManual(row) else { return }; tracksTarget = TracksTarget(result: result)
    }
    private func choose(_ row: SourceFilterRow) {
        guard let selected = filter.take(row) else { return }
        let tracks = pick(for: row.result); filter.close(); dismiss(); onPick(selected, tracks)
    }
    private func record(_ probe: SourceTrackProbe, for result: SourceResult) {
        guard result.filterSelection?.current == true else { return }
        if !probe.audio.isEmpty || !probe.subtitles.isEmpty { probes[result.index] = probe }
        filter.recordProbe(result, probe: probe)
    }

    private func pick(for result: SourceResult) -> ManualTrackPick? {
        guard let overrides = trackOverrides[result.index], !overrides.isEmpty,
              let probe = probes[result.index] else { return nil }
        return ManualTrackPick(overrides: overrides, audio: probe.audio, subtitles: probe.subtitles)
    }

    private func load() async {
        filter.appear()
        guard filter.current else { return }
        do {
            let preferences = try await ManualTrackPreferences.current(content: contentPreference, context: filter.context)
            guard filter.current else { return }; trackPreferences = preferences
        } catch { filter.preferenceFailed(error) }
    }
}
#endif
