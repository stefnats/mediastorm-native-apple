import SwiftUI

/// Full-screen list of the backend's indexer / scraper results for one movie or episode, below
/// the title's copies in the profile's libraries (as the Expo app lists them first).
struct SourcePickerView: View {
    let title: DetailsTarget
    let episode: Episode?
    /// The movie's or episode's library copies, listed above the results.
    var libraryVersions: [LibraryVersion] = []
    var onPickLibrary: (LibraryVersion) -> Void = { _ in }
    /// The title's per-title track languages, for the defaults a long press shows.
    let contentPreference: ContentPreference?
    /// The source, with the track picks made for it this visit (nil = the server's choice).
    let onPick: (SourceResult, ManualTrackPick?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var filter: SourceFilterModel
    @State private var filterControls = false
    private var results: [SourceResult] { filter.rows.map(\.result) }
    private var isLoading: Bool { filter.loading }
    private var error: String? { filter.error }
    private var health: [Int: SourceHealth] { filter.health }
    @State private var trackPreferences = ManualTrackPreferences()
    /// Track picks and probes by result index, kept for the visit (Expo `trackOverrides`).
    @State private var trackOverrides: [Int: ManualTrackOverrides] = [:]
    @State private var probes: [Int: SourceTrackProbe] = [:]
    /// The result whose tracks are shown (long press).
    @State private var tracksTarget: TracksTarget?
    /// A long press's release can also arrive as a Select; it is ignored until then.
    @State private var suppressSelectUntil = Date.distantPast

    init(title: DetailsTarget, episode: Episode?, libraryVersions: [LibraryVersion] = [], onPickLibrary: @escaping (LibraryVersion) -> Void = { _ in }, contentPreference: ContentPreference?, onPick: @escaping (SourceResult, ManualTrackPick?) -> Void) {
        self.title = title; self.episode = episode; self.libraryVersions = libraryVersions; self.onPickLibrary = onPickLibrary
        self.contentPreference = contentPreference; self.onPick = onPick
        _filter = StateObject(wrappedValue: SourceFilterModel(title: title, episode: episode))
    }

    struct TracksTarget: Identifiable {
        let result: SourceResult
        var id: Int { result.index }
    }

    private var heading: String {
        guard let episode else { return title.name }
        return "\(title.name) · \(episode.code)"
    }

    var body: some View {
        // A plain scroll view of focusable rows: focus moving down scrolls it, so every
        // result is reachable with the remote.
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(heading).font(.title2.weight(.semibold))
                    if !isLoading, error == nil, !results.isEmpty {
                        Text(results.count == 1 ? "1 source" : "\(results.count) sources")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 24)

                SourceFilterStatus(model: filter, controls: $filterControls)
                if !libraryVersions.isEmpty {
                    Text(libraryVersions.count == 1 ? String(localized: "In your libraries")
                                                    : String(localized: "\(libraryVersions.count) in your libraries"))
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(libraryVersions) { version in
                        Button {
                            guard filter.permitsLibrary else { return }
                            filter.close(); dismiss()
                            onPickLibrary(version)
                        } label: {
                            LibraryVersionRow(version: version)
                        }
                        .buttonStyle(SourceRowStyle())
                    }
                    Text("Streams").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 24)
                }

                if isLoading {
                    HStack(spacing: 24) {
                        ProgressView()
                        Text(filter.supported ? "Reading saved source view…" : "Searching sources…").foregroundStyle(.secondary)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                } else if results.isEmpty {
                    Text("No sources found").foregroundStyle(.secondary)
                } else {
                    ForEach(filter.rows) { row in
                        let result = row.result
                        Button {
                            guard Date() >= suppressSelectUntil, let selected = filter.take(row) else { return }
                            let tracks = pick(for: result); filter.close(); dismiss()
                            onPick(selected, tracks)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                SourceRow(result: result, health: health[result.index], hasTrackPicks: !(trackOverrides[result.index]?.isEmpty ?? true))
                                if filter.supported { Text(SourceFilterLabels.verdict(row.verdict, basis: filter.page?.filters.basis ?? "candidate")).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                        .buttonStyle(SourceRowStyle())
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            showTracks(row)
                        })
                    }
                }
            }
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
        .scrollClipDisabled()
        .background { SourcePickerBackdrop(url: title.backdropURL) }
        .onExitCommand { filter.close(); dismiss() }
        .task { await load() }
        .onDisappear { if tracksTarget == nil && !filterControls { filter.close() } }
        .onChange(of: filter.page?.viewId) { probes = [:]; trackOverrides = [:] }
        .onChange(of: filter.latestEvidence) { before, after in
            for (index, evidence) in after where before[index]?.sourceVersion != evidence.sourceVersion { trackOverrides[index] = nil }
        }
        .fullScreenCover(item: $tracksTarget) { target in
            let index = target.result.index
            SourceTracksView(
                result: target.result, cached: probes[index],
                onProbe: { probe in record(probe, for: target.result) },
                backdropURL: title.backdropURL, preferences: trackPreferences,
                overrides: Binding(get: { trackOverrides[index] ?? ManualTrackOverrides() },
                                   set: { trackOverrides[index] = $0 })
            ) { pick in
                // Leave the track page, then the picker, then play.
                guard let selected = filter.takeManual(target.result) else { return }
                let admitted = filter.captureAdmission()
                Task {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    guard admitted(), !Task.isCancelled else { return }
                    filter.close(); dismiss()
                    onPick(selected, pick)
                }
            }
        }
    }

    // MARK: Tracks

    /// Long press: probe the source and list its tracks (the Expo TV track modal).
    private func showTracks(_ row: SourceFilterRow) {
        guard let result = filter.beginManual(row) else { return }
        suppressSelectUntil = Date().addingTimeInterval(1.5)
        tracksTarget = TracksTarget(result: result)
    }

    private func record(_ probe: SourceTrackProbe, for result: SourceResult) {
        guard result.filterSelection?.current == true else { return }
        if !probe.audio.isEmpty || !probe.subtitles.isEmpty { probes[result.index] = probe }
        filter.recordProbe(result, probe: probe)
    }

    /// The picks made for `result` this visit, which a plain Select also plays with (as Expo).
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

/// Full-width row that highlights on focus, like a grouped list row (also the subtitle search list).
struct SourceRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isFocused ? Color.white : Color.white.opacity(0.08))
                )
                .scaleEffect(configuration.isPressed ? 0.99 : isFocused ? 1.02 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}
