import Foundation
import Combine

struct StoredMediaCard: Identifiable {
    let ordinal: Int
    let entry: BrowseEntry
    var watching: ContinueWatchingItem?
    var hidden: HiddenItem?
    var id: String { "\(ordinal):\(entry.id)" }
    var card: HomeCard { watching.map(HomeCard.init) ?? HomeCard(entry) }
}

/// A saved view has one original viewer and one accepted filter generation. It
/// never invokes discovery, resolve, probe, artwork fill or a random provider pick.
@MainActor
final class StoredMediaBrowseModel: ObservableObject {
    let list: BrowseList
    let context: SourceActionContext
    private let api: any StoredMediaAPI
    private var generation = 0
    private var closed = false
    private var task: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var observation: StoredMediaObservation?
    private var fetched = 0
    @Published var draft: BrowseOptions
    @Published private(set) var applied: BrowseOptions
    @Published private(set) var rows: [StoredMediaCard] = []
    @Published private(set) var total: Int?
    @Published private(set) var capability = StoredMediaCapability()
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var retired = false
    init(list: BrowseList, options: BrowseOptions = BrowseOptions(), api: any StoredMediaAPI = APIClient.shared) {
        self.list = list; self.api = api; context = api.sourceContext(); draft = options; applied = options
    }
    var current: Bool { !closed && !retired && api.isCurrent(context) && (observation?.current() ?? true) }
    var hasMore: Bool { total.map { fetched < $0 } ?? true }
    func appear() { if total == nil && !loading && !retired { loadMore() } }
    func close() { closed = true; generation += 1; task?.cancel(); expiry?.cancel(); loading = false; rows = [] }
    func reopen() { guard closed, api.isCurrent(context) else { return }; closed = false; refresh() }
    func apply() {
        guard !closed, api.isCurrent(context) else { return retire(StoredMediaFailure.changed) }
        do { _ = try draft.savedQuery() } catch { self.error = error.localizedDescription; return }
        applied = draft; reset()
    }
    func refresh() {
        guard !closed, api.isCurrent(context) else { return retire(StoredMediaFailure.changed) }
        reset()
    }
    private func reset() {
        generation += 1; task?.cancel(); expiry?.cancel(); observation = nil; fetched = 0
        rows = []; total = nil; retired = false; error = nil; loading = false; loadMore()
    }
    func clearSavedFilters() {
        draft.originalLanguages = []; draft.includeUnknownOriginalLanguage = false; draft.storedMedia = StoredMediaFilters()
    }
    func loadMore() {
        guard current else { return retire(api.isCurrent(context) ? .expired : .changed) }
        guard !loading, hasMore else { return }
        let owner = generation, options = applied, offset = fetched
        loading = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if owner == generation { loading = false; task = nil } }
            do {
                guard current, owner == generation else { return }
                let page = try await api.savedMediaPage(list, options: options, limit: 60, offset: offset, context: context)
                try Task.checkCancellation()
                guard current, owner == generation else { return }
                try accept(page, offset: offset)
            } catch {
                guard owner == generation, !closed, !error.isCancellation else { return }
                // No partial filtered grid is kept after an unsupported or changed
                // response; retry is an explicit read of the same selected view.
                rows = []; total = nil; fetched = 0; self.error = error.localizedDescription
                if !api.isCurrent(context) { retire(StoredMediaFailure.changed) }
            }
        }
    }
    private func accept(_ page: BrowsePage, offset: Int) throws {
        try page.savedCapability.require(applied)
        if let observation {
            guard let next = page.savedObservation, observation.identity == next.identity else { throw StoredMediaFailure.changed }
        }
        guard page.total >= offset + page.entries.count, page.entries.count <= 60,
              !page.entries.isEmpty || offset >= page.total,
              page.savedHidden == nil || page.savedHidden!.count == page.entries.count,
              page.savedWatching == nil || page.savedWatching!.count == page.entries.count else { throw StoredMediaFailure.invalid }
        let incoming = page.entries.enumerated().map { index, entry in
            StoredMediaCard(ordinal: offset + index, entry: entry, watching: page.savedWatching?[index], hidden: page.savedHidden?[index])
        }
        capability = page.savedCapability; rows += incoming; total = page.total; fetched += page.entries.count
        if observation == nil, let observed = page.savedObservation {
            observation = observed
            let owner = generation
            expiry = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: observed.deadline) } catch { return }
                guard let self, owner == generation, !closed else { return }
                retire(StoredMediaFailure.expired)
            }
        }
    }
    func unhide(_ row: StoredMediaCard) {
        guard current, !loading, let hidden = row.hidden, rows.contains(where: { $0.id == row.id }) else { return }
        let owner = generation; loading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if owner == generation { loading = false; task = nil } }
            do {
                try await api.savedMediaUnhide(hidden, context: context)
                try Task.checkCancellation()
                guard current, owner == generation else { return }
                // The acknowledged mutation changes total/order; reload the original
                // selection rather than replaying a write or guessing a replacement.
                refresh()
            } catch {
                guard !closed, owner == generation, !error.isCancellation else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func retire(_ failure: StoredMediaFailure) {
        generation += 1; task?.cancel(); expiry?.cancel(); task = nil; expiry = nil
        rows = []; loading = false; retired = true; error = failure.localizedDescription
    }
}
