import SwiftUI

enum SourceFilterLabels {
    static func verdict(_ value: String, basis: String) -> String {
        switch value {
        case "unknown": "Unknown facts included by the selected policy"
        case "match": basis == "candidate" ? "Matches release claims" : "Matches existing file metadata"
        default: "Unfiltered source"
        }
    }
}

struct SourceFilterControls: View {
    @Binding var filters: SourceFilters
    var body: some View {
        Form {
            Section("Evidence basis") {
                Picker("Match against", selection: Binding(get: { filters.basis }, set: { filters.chooseBasis($0) })) {
                    Text("Release claims").tag("candidate")
                    Text("Existing file metadata").tag("probed")
                }
                Text(filters.basis == "candidate" ? "Labels describe release claims; they do not confirm an audio track or device output." : "Only existing stored probe metadata is used. Applying a filter never probes a source.")
                    .font(.footnote)
            }
            Section("Criteria") {
                field("Audio language", value: $filters.audioLanguage, choices: MediaFilterValues.languages, language: true)
                field("Subtitle language", value: $filters.subtitleLanguage, choices: MediaFilterValues.languages, language: true)
                field("Video codec", value: $filters.videoCodec, choices: MediaFilterValues.videoCodecs)
                field("Dynamic range", value: $filters.dynamicRange, choices: MediaFilterValues.ranges)
                if filters.basis == "candidate" {
                    field("Claimed minimum resolution", value: $filters.claimedResolutionAtLeast, choices: MediaFilterValues.heights.map { "\($0)p" })
                } else {
                    Picker("Minimum existing file height", selection: $filters.heightAtLeast) {
                        Text("Any").tag(Int?.none)
                        ForEach(MediaFilterValues.heights, id: \.self) { Text("\($0)p").tag(Optional($0)) }
                    }
                    field("Audio codec", value: $filters.audioCodec, choices: MediaFilterValues.audioCodecs)
                    Toggle("Require audio description", isOn: Binding(get: { filters.audioDescription == true }, set: { filters.audioDescription = $0 ? true : nil }))
                }
                Picker("Unknown observations", selection: $filters.unknown) {
                    Text("Include unknown").tag("include"); Text("Exclude unknown").tag("exclude")
                }
            }
            Button("Clear criteria", role: .destructive) { filters = SourceFilters() }
        }
    }
    private func field(_ title: LocalizedStringKey, value: Binding<String?>, choices: [String], language: Bool = false) -> some View {
        Picker(title, selection: value) {
            Text("Any").tag(String?.none)
            ForEach(Array(Set(choices + [value.wrappedValue].compactMap { $0 })).sorted(), id: \.self) { code in
                Text(language ? MediaFilterValues.label(code) : code).tag(Optional(code))
            }
        }
    }
}

struct SourceFilterStatus: View {
    @ObservedObject var model: SourceFilterModel
    @Binding var controls: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.supported, let page = model.page {
                Text(page.filters.basis == "candidate" ? "Release claims" : "Existing file metadata").font(.callout)
                Text("\(page.total) results · \(page.matchedTotal) matched · \(page.unknownTotal) unknown")
                Text("\(page.coverage.retainedCandidates) retained candidates" + (page.coverage.truncated ? " · search retention was truncated" : ""))
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Source filters") { controls = true }
                    if model.needsApply { Button("Apply again") { model.apply() }.disabled(model.loading || model.needsReload) }
                    if model.hasMore { Button("Load more") { model.more() }.disabled(model.loading) }
                }
            } else if !model.loading && !model.needsReload {
                Text("This server returned a legacy source list. Source filters are unavailable.").font(.footnote)
            }
            if model.needsReload || model.error != nil {
                Button("Reload source search") { model.reload() }.disabled(model.loading || !model.current || model.denied)
                if model.denied { Text("Restore profile access, then close and reopen this source list.").font(.footnote) }
            }
        }
        .sheet(isPresented: $controls) {
            NavigationStack {
                SourceFilterControls(filters: $model.draft)
                    .navigationTitle("Source filters")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Apply") { controls = false; model.apply() } }
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.draft = model.page?.filters ?? SourceFilters(); controls = false } }
                    }
            }
        }
    }
}
