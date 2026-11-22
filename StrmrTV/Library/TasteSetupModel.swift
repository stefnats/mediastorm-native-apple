import Combine
import Foundation

@MainActor
final class TasteSetupModel: ObservableObject {
    let context: SourceActionContext
    @Published private(set) var reply: TasteSetupReply?
    @Published private(set) var selected: [Title] = []
    @Published private(set) var candidates: [Title] = []
    @Published private(set) var busy = false
    @Published private(set) var searching = false
    @Published private(set) var finished = false
    @Published private(set) var message: String?
    @Published private(set) var searchError: String?
    @Published var intro: Bool
    private let api: any PersonalTasteAPI
    private let onSaved: @MainActor (SourceActionContext) -> Void
    private var initial: TasteSetupReply?
    private var closed = false
    private var searchGeneration = 0

    init(context: SourceActionContext, initial: TasteSetupReply? = nil, intro: Bool = false,
         api: any PersonalTasteAPI = APIClient.shared, onSaved: @escaping @MainActor (SourceActionContext) -> Void = PersonalTasteChanges.saved) {
        self.context = context; self.initial = initial; self.intro = intro; self.api = api; self.onSaved = onSaved
    }
    func close() { closed = true; searchGeneration += 1 }
    private func check() throws {
        try Task.checkCancellation()
        guard !closed, api.isCurrent(context) else { throw CancellationError() }
    }
    func load() async {
        guard !busy, !closed else { return }
        busy = true; message = nil; reply = nil; finished = false
        defer { busy = false }
        do {
            try check()
            let value: TasteSetupReply
            if let initial { value = initial; self.initial = nil }
            else { value = try await api.readTasteSetup(context) }
            try check(); try value.validate()
            reply = value; selected = value.titles
            intro = intro && value.status == "new" && value.available
        } catch { if !closed, !Task.isCancelled, api.isCurrent(context) { message = PersonalTasteError.message(error) } }
    }
    func contains(_ title: Title) -> Bool { selected.contains { PersonalTasteWire.same($0, title) } }
    func toggle(_ title: Title) {
        guard !busy, !closed, !finished, api.isCurrent(context), reply?.available == true,
              PersonalTasteWire.valid(title), candidates.contains(title) || selected.contains(title) else { return }
        if contains(title) { selected.removeAll { PersonalTasteWire.same($0, title) } }
        else if selected.count < 40 { selected.append(title) }
        else { message = String(localized: "Choose up to 40 titles.") }
    }
    func clearSelection() {
        guard !busy, !closed, !finished, api.isCurrent(context), reply?.available == true else { return }
        selected = []
    }
    func search(kind: String, query: String) async {
        guard !busy, !closed, !finished, !intro, reply?.available == true, reply?.mediaTypes.contains(kind) == true else { return }
        searchGeneration += 1
        let generation = searchGeneration
        searching = true; searchError = nil
        do {
            try check()
            let values = try await api.tasteCandidates(context, kind: kind, query: query)
            try check()
            guard generation == searchGeneration, !finished else { return }
            guard values.count <= 24, values.allSatisfy({ PersonalTasteWire.valid($0) && ($0.isMovie ? "movie" : "series") == kind }) else { throw PersonalTasteError.unavailable }
            candidates = values.enumerated().filter { index, value in !values.prefix(index).contains { PersonalTasteWire.same($0, value) } }.map(\.element)
            searching = false
        } catch {
            if generation == searchGeneration, !closed, !Task.isCancelled, api.isCurrent(context) {
                searching = false; searchError = PersonalTasteError.message(error)
            }
        }
    }
    func finish(action: String = "save", reset: Bool = false) async {
        guard !busy, !closed, !finished, let previous = reply else { return }
        guard reset || previous.available && ["save", "skip", "history"].contains(action),
              reset || action != "history" || previous.canUseHistory else { return }
        let desired = action == "save" ? selected : []
        busy = true; message = nil; searching = false; searchGeneration += 1
        defer { busy = false }
        do {
            try check()
            let value: TasteSetupReply
            if reset { value = try await api.clearTasteSetup(context) }
            else { value = try await api.saveTasteSetup(context, action: action, titles: desired) }
            try check(); try value.validate()
            let expected = reset ? "new" : action == "skip" ? "skipped" : "completed"
            guard value.status == expected else { throw PersonalTasteError.unavailable }
            if reset {
                guard value.titles.isEmpty, value.source.isEmpty else { throw PersonalTasteError.unavailable }
            } else if action == "save" || action == "history" {
                guard value.source == (action == "save" ? "manual" : "history") else { throw PersonalTasteError.unavailable }
            }
            reply = value; selected = value.titles; finished = true
            onSaved(context)
        } catch {
            reply = nil // Explicit re-read is required after any ambiguous save.
            if !closed, !Task.isCancelled, api.isCurrent(context) { message = PersonalTasteError.message(error) }
        }
    }
}

/// One optional read per actual profile activation. A cancelled/covered Home may
/// try when visible again; a failed optional request never interrupts viewing.
@MainActor
final class TasteSetupOffer {
    static let shared = TasteSetupOffer()
    private var activation: UUID?
    private var attempted = false
    func check(context: SourceActionContext, activation: UUID, api: any PersonalTasteAPI = APIClient.shared,
               visible: @MainActor () -> Bool) async -> TasteSetupReply? {
        if self.activation != activation { self.activation = activation; attempted = false }
        guard !attempted, visible(), api.isCurrent(context) else { return nil }
        attempted = true
        do {
            let reply = try await api.readTasteSetup(context)
            try Task.checkCancellation()
            guard self.activation == activation, api.isCurrent(context) else { return nil }
            guard visible() else { attempted = false; return nil }
            try reply.validate()
            return reply.status == "new" && reply.available ? reply : nil
        } catch is CancellationError {
            if self.activation == activation { attempted = false }
            return nil
        } catch { return nil }
    }
}
