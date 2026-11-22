import SwiftUI
import UIKit

/// Manual editing and the optional first offer share the same staged editor.
@MainActor
struct TasteSetupView: View {
    @StateObject private var model: TasteSetupModel
    @State private var query = ""
    @State private var kind = "movie"
    @State private var operation: Task<Void, Never>?
    @State private var search: Task<Void, Never>?
    @State private var confirmingReset = false
    @Environment(\.dismiss) private var dismiss

    init(context: SourceActionContext = APIClient.shared.sourceContext(), initial: TasteSetupReply? = nil, intro: Bool = false) {
        _model = StateObject(wrappedValue: TasteSetupModel(context: context, initial: initial, intro: intro))
    }
    var body: some View {
        List {
            Section {
                Text("Choose a few favorite films or shows to help this profile's recommendations. Nothing is watched, downloaded or added to a list.")
                    .font(.callout)
            }
            if let reply = model.reply {
                if reply.available {
                    if model.intro {
                        Section {
                            Button("Choose favorites") { model.intro = false }
                            if reply.canUseHistory { Button("Use this profile's existing history") { finish("history") } }
                            Button("Skip for now") { finish("skip") }
                        }
                        .disabled(model.busy)
                    } else {
                        selection.disabled(model.busy)
                        Section("Find starting titles") {
                            Picker("Type", selection: $kind) {
                                ForEach(reply.mediaTypes, id: \.self) { Text($0 == "movie" ? "Films" : "Shows").tag($0) }
                            }
                            TextField("Search titles", text: $query).onSubmit { find() }
                            Button("Search") { find() }
                            if model.searching { ProgressView() }
                            if let error = model.searchError { Text(error).font(.caption).foregroundStyle(.secondary) }
                            ForEach(model.candidates, id: \.self) { title in
                                Button { model.toggle(title) } label: {
                                    HStack {
                                        Text(title.name)
                                        Spacer()
                                        if model.contains(title) { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                        .disabled(model.busy)
                        Section {
                            Button("Save selection") { finish("save") }
                            if reply.canUseHistory { Button("Replace with this profile's existing history") { finish("history") } }
                            Button("Skip for now") { finish("skip") }
                        }
                        .disabled(model.busy)
                    }
                } else {
                    Text("Starting interests are unavailable for this profile. You can still reset previously saved interests.")
                }
                Button("Reset saved starting interests", role: .destructive) { confirmingReset = true }
                    .disabled(model.busy)
            }
            if let message = model.message { Text(message).foregroundStyle(.secondary) }
            if model.busy { ProgressView() }
            if model.reply == nil, !model.busy {
                Button("Reload starting interests") { operation = Task { await model.load() } }
            }
            Button("Cancel", role: .cancel) { dismiss() }
        }
        .navigationTitle("Starting interests")
        .task {
            await model.load()
            kind = model.reply?.mediaTypes.first ?? "movie"
        }
        .onChange(of: model.intro) { _, intro in if !intro { find() } }
        .onChange(of: kind) { _, _ in find() }
        .onChange(of: model.finished) { _, finished in if finished { dismiss() } }
        .onDisappear { model.close(); operation?.cancel(); search?.cancel() }
        .confirmationDialog("Reset this profile's starting interests?", isPresented: $confirmingReset) {
            Button("Reset starting interests", role: .destructive) { operation = Task { await model.finish(reset: true) } }
            Button("Cancel", role: .cancel) {}
        }
    }
    private var selection: some View {
        Section("Selected: \(model.selected.count) of 40") {
            ForEach(model.selected, id: \.self) { title in
                Button { model.toggle(title) } label: { Label(title.name, systemImage: "checkmark.circle") }
            }
            Button("Clear selection") { model.clearSelection() }
        }
    }
    private func find() {
        search?.cancel()
        let selectedKind = kind, text = query
        search = Task { await model.search(kind: selectedKind, query: text) }
    }
    private func finish(_ action: String) {
        search?.cancel()
        operation = Task { await model.finish(action: action) }
    }
}

private struct TasteOfferKey: Hashable { let ready: Bool; let activation: UUID }
private struct TasteOfferPresentation: Identifiable {
    let id = UUID()
    let context: SourceActionContext
    let reply: TasteSetupReply
}

@MainActor
private struct TasteSetupOfferModifier: ViewModifier {
    let ready: Bool
    @ObservedObject private var session = AppSession.shared
    @State private var presentation: TasteOfferPresentation?
    private func visible() -> Bool {
        guard ready, session.phase == .ready, !session.protectedBrowsingBlocked,
              session.pinChallenge == nil, !session.hasProtectedPlaybackPresentation else { return false }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            if scene.windows.first(where: \.isKeyWindow)?.rootViewController?.presentedViewController != nil { return false }
        }
        return true
    }
    func body(content: Content) -> some View {
        content
            .task(id: TasteOfferKey(ready: ready, activation: session.resumeActivation)) {
                let context = APIClient.shared.sourceContext()
                if let reply = await TasteSetupOffer.shared.check(context: context, activation: session.resumeActivation, visible: visible),
                   !Task.isCancelled, visible(), APIClient.shared.isCurrent(context) {
                    presentation = TasteOfferPresentation(context: context, reply: reply)
                }
            }
            .sheet(item: $presentation) { offer in
                NavigationStack { TasteSetupView(context: offer.context, initial: offer.reply, intro: true) }
            }
    }
}

extension View {
    @MainActor func offerTasteSetup(ready: Bool) -> some View { modifier(TasteSetupOfferModifier(ready: ready)) }
}
