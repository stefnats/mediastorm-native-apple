import Combine
import Foundation

@MainActor
final class TitleRatingModel: ObservableObject {
    let target: DetailsTarget
    let context: SourceActionContext
    @Published private(set) var rating: PersonalTitleRating?
    @Published var selected: PersonalTitleRating = .none
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var saved = false
    private let api: any PersonalTasteAPI
    private let onSaved: @MainActor (SourceActionContext) -> Void
    private var closed = false

    init(target: DetailsTarget, context: SourceActionContext, api: any PersonalTasteAPI = APIClient.shared,
         onSaved: @escaping @MainActor (SourceActionContext) -> Void = PersonalTasteChanges.saved) {
        self.target = target; self.context = context; self.api = api; self.onSaved = onSaved
    }
    func close() { closed = true }
    private func check() throws {
        try Task.checkCancellation()
        guard !closed, api.isCurrent(context) else { throw CancellationError() }
    }
    func load() async {
        guard !busy, !closed else { return }
        busy = true; rating = nil; message = nil; saved = false
        defer { busy = false }
        do {
            try check()
            let value = try await api.readRating(target, context: context)
            try check()
            rating = value; selected = value
        } catch { if !closed, !Task.isCancelled, api.isCurrent(context) { message = PersonalTasteError.message(error) } }
    }
    func save() async {
        guard !busy, !closed, !saved, rating != nil else { return }
        let desired = selected
        busy = true; message = nil
        defer { busy = false }
        do {
            try check()
            let value = try await api.setRating(desired, target: target, context: context)
            try check()
            guard value == desired else { throw PersonalTasteError.unavailable }
            rating = value; selected = value; saved = true
            onSaved(context)
        } catch {
            rating = nil // Unknown is not a rollback and cannot be saved again without a read.
            if !closed, !Task.isCancelled, api.isCurrent(context) { message = PersonalTasteError.message(error) }
        }
    }
}
