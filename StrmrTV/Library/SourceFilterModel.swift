import Foundation
import Combine

/// This local receipt is not a backend grant. It permits the exact manual row
/// after its own probe invalidated the displayed filter view, until this original
/// picker/source lifetime ends. Equal copied rows cannot acquire the receipt.
@MainActor
final class SourceFilterSelection {
    weak var owner: SourceFilterModel?
    let row: SourceFilterRow
    let source: Int
    let manual: Int
    let context: SourceActionContext
    init(owner: SourceFilterModel, row: SourceFilterRow, source: Int, manual: Int) {
        self.owner = owner; self.row = row; self.source = source; self.manual = manual; context = owner.context
    }
    var current: Bool { owner?.acceptsManual(self) == true }
    func probed(_ value: SourceTrackProbe) { owner?.probeChanged(self, evidence: value.evidence) }
    func failed(_ error: Error) { owner?.probeFailed(self, error: error) }
    func closed() { owner?.endManual(self) }
}

@MainActor
final class SourceFilterModel: ObservableObject {
    let title: DetailsTarget
    let episode: Episode?
    let target: SourceFilterTarget
    let context: SourceActionContext
    private let api: any SourceFilterAPI
    private let now: () -> Date
    private var closed = false
    private var source = 0
    private var view = 0
    private var manual = 0
    private var task: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var consumed = Set<String>()
    @Published private(set) var page: SourceFilterPage?
    @Published private(set) var rows: [SourceFilterRow] = []
    @Published private(set) var supported = false
    @Published private(set) var denied = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var needsReload = false
    @Published private(set) var needsApply = false
    @Published private(set) var health: [Int: SourceHealth] = [:]
    @Published private(set) var latestEvidence: [Int: SourceFilterEvidence] = [:]
    @Published var draft = SourceFilters()
    init(title: DetailsTarget, episode: Episode?, api: any SourceFilterAPI = APIClient.shared, now: @escaping () -> Date = Date.init) {
        self.title = title; self.episode = episode; target = SourceFilterTarget(title: title, episode: episode)
        self.api = api; self.now = now; context = api.sourceContext()
    }
    var current: Bool { !closed && api.isCurrent(context) }
    var permitsLibrary: Bool { current && !denied }
    var live: Bool { current && !denied && !needsReload && !needsApply && (page.map { now() < $0.expiresAt } ?? true) }
    var hasMore: Bool { live && supported && page?.nextCursor != nil }
    func appear() { if rows.isEmpty && page == nil && error == nil && !loading && !closed { reload() } }
    func close() {
        closed = true; source += 1; view += 1; manual += 1
        task?.cancel(); expiry?.cancel(); healthTask?.cancel(); rows = []; health = [:]; loading = false
    }
    /// Only initial admission and an explicit Reload issue a provider search.
    func reload() {
        guard current, !loading, !denied else { return }
        SourceSearch.retire(title: title, query: query, numbering: episode?.numbering, context: context)
        let wanted = supported ? draft : SourceFilters()
        source += 1; view += 1; manual += 1; let owner = source, ownedView = view
        task?.cancel(); expiry?.cancel(); healthTask?.cancel(); consumed = []
        page = nil; rows = []; health = [:]; latestEvidence = [:]; supported = false; needsReload = false; needsApply = false; loading = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if owner == source && ownedView == view { loading = false; task = nil } }
            do {
                try Task.checkCancellation(); try target.validate(); guard current, owner == source, ownedView == view else { return }
                let reply = try await api.sourceFilterSearch(title: title, episode: episode, context: context)
                try Task.checkCancellation(); guard current, owner == source, ownedView == view else { return }
                switch reply {
                case let .legacy(rows): self.rows = rows; supported = false; draft = SourceFilters(); rememberLegacy(rows)
                case let .supported(page):
                    try validate(page, filters: SourceFilters()); try accept(page); supported = true; draft = wanted
                    if wanted != page.filters {
                        let filtered = try await api.sourceFilterPage(snapshot: page.snapshotId, filters: wanted, cursor: nil, context: context)
                        try Task.checkCancellation(); guard current, owner == source, ownedView == view else { return }
                        try validate(filtered, filters: wanted, snapshot: page.snapshotId); try accept(filtered)
                    }
                }
                startHealth()
            } catch { if current && owner == source && ownedView == view && !error.isCancellation { fail(error, reload: true) } }
        }
    }
    func apply() {
        guard current, supported, !needsReload, let existing = page else { return }
        let requested: SourceFilters
        do { requested = try draft.validated() } catch { self.error = error.localizedDescription; return }
        view += 1; manual += 1; let wanted = view, owner = source
        task?.cancel(); healthTask?.cancel(); consumed = []; rows = []; loading = true; error = nil; needsApply = false
        task = Task { [weak self] in
            guard let self else { return }
            defer { if owner == source && wanted == view { loading = false; task = nil } }
            do {
                try Task.checkCancellation(); guard current, owner == source, wanted == view else { return }
                let result = try await api.sourceFilterPage(snapshot: existing.snapshotId, filters: requested, cursor: nil, context: context)
                try Task.checkCancellation(); guard current, owner == source, wanted == view else { return }
                try validate(result, filters: requested, snapshot: existing.snapshotId); try accept(result); startHealth()
            } catch { if current && owner == source && wanted == view && !error.isCancellation { fail(error) } }
        }
    }
    func more() {
        guard hasMore, !loading, let existing = page, let cursor = existing.nextCursor, !consumed.contains(cursor) else { return }
        let owner = source, wanted = view; loading = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if owner == source && wanted == view { loading = false; task = nil } }
            do {
                try Task.checkCancellation(); guard current, owner == source, wanted == view else { return }
                let result = try await api.sourceFilterPage(snapshot: existing.snapshotId, filters: existing.filters, cursor: cursor, context: context)
                try Task.checkCancellation(); guard current, owner == source, wanted == view else { return }
                try validate(result, filters: existing.filters, snapshot: existing.snapshotId)
                guard result.viewId == existing.viewId, result.expiresAt == existing.expiresAt, result.total == existing.total,
                      result.matchedTotal == existing.matchedTotal, result.unknownTotal == existing.unknownTotal, result.coverage == existing.coverage,
                      result.nextCursor != cursor, result.nextCursor.map({ !consumed.contains($0) }) ?? true,
                      Set(rows.map(\.id)).isDisjoint(with: result.rows.map(\.id)) else { throw SourceFilterFailure.changed }
                let count = rows.count + result.rows.count
                guard count <= result.total, result.nextCursor == nil ? count == result.total : count < result.total else { throw SourceFilterFailure.changed }
                rows += result.rows; page = result; consumed.insert(cursor); scheduleExpiry(result); rememberComplete(); startHealth()
            } catch { if current && owner == source && wanted == view && !error.isCancellation { fail(error) } }
        }
    }
    private func validate(_ value: SourceFilterPage, filters: SourceFilters, snapshot: String? = nil) throws {
        guard value.target == target, value.filters == filters, snapshot == nil || snapshot == value.snapshotId,
              value.expiresAt > now(), value.expiresAt.timeIntervalSince(now()) <= 900 else { throw SourceFilterFailure.expired }
    }
    private func accept(_ value: SourceFilterPage) throws {
        guard value.nextCursor == nil ? value.rows.count == value.total : value.rows.count < value.total else { throw SourceFilterFailure.invalid }
        page = value; rows = value.rows; needsApply = false; needsReload = false; error = nil
        scheduleExpiry(value); rememberComplete()
    }
    private func scheduleExpiry(_ page: SourceFilterPage) {
        expiry?.cancel(); let owner = source, wanted = view
        let delay = max(0, page.expiresAt.timeIntervalSince(now()))
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, current, owner == source, wanted == view else { return }
            view += 1; task?.cancel(); task = nil; loading = false; healthTask?.cancel()
            needsApply = true; error = SourceFilterFailure.expired.localizedDescription
        }
    }
    func canSelect(_ row: SourceFilterRow) -> Bool { live && !loading && rows.contains(where: { $0 === row }) }
    func take(_ row: SourceFilterRow) -> SourceResult? {
        guard canSelect(row) else { return nil }; manual += 1; return row.result
    }
    func beginManual(_ row: SourceFilterRow) -> SourceResult? {
        guard canSelect(row) else { return nil }; manual += 1
        var result = row.result; result.filterSelection = SourceFilterSelection(owner: self, row: row, source: source, manual: manual); return result
    }
    func acceptsManual(_ selection: SourceFilterSelection) -> Bool {
        current && !needsReload && source == selection.source && manual == selection.manual && selection.owner === self &&
            selection.context == context && (page.map { now() < $0.expiresAt && selection.row.result.snapshotID == $0.snapshotId } ?? (selection.row.result.snapshotID == nil))
    }
    func takeManual(_ result: SourceResult) -> SourceResult? {
        guard let receipt = result.filterSelection, acceptsManual(receipt) else { return nil }
        manual += 1; var result = result; result.filterSelection = nil; return result
    }
    func endManual(_ selection: SourceFilterSelection) { if acceptsManual(selection) { manual += 1 } }
    func captureAdmission() -> () -> Bool {
        let owner = source, receipt = manual, until = page?.expiresAt
        return { [weak self] in
            guard let self else { return false }
            return current && !needsReload && owner == source && receipt == manual && (until.map { now() < $0 } ?? true)
        }
    }
    func probeChanged(_ selection: SourceFilterSelection, evidence: SourceFilterEvidence?) {
        guard acceptsManual(selection), supported else { return }
        if let evidence, evidence.candidateVersion == selection.row.result.candidateVersion { latestEvidence[selection.row.id] = evidence }
        else { latestEvidence[selection.row.id] = nil }
        // A real explicit probe may change the existing-file version. Even a
        // missing optional evidence reply requires reapplying the server view;
        // the exact manual result remains available under its separate receipt.
        view += 1; needsApply = true; loading = false; task?.cancel(); task = nil; healthTask?.cancel()
        error = SourceFilterFailure.changed.localizedDescription
    }
    func probeFailed(_ selection: SourceFilterSelection, error: Error) {
        guard acceptsManual(selection) else { return }; fail(error)
    }
    func preferenceFailed(_ error: Error) {
        guard current, !error.isCancellation else { return }; fail(error, reload: true)
    }
    func recordProbe(_ result: SourceResult, probe: SourceTrackProbe) {
        guard let receipt = result.filterSelection, acceptsManual(receipt) else { return }
        let debrid = result.serviceType.lowercased() == "debrid"
        health[result.index] = SourceHealth(state: probe.playable ? (debrid ? "cached" : "healthy") : (debrid ? "not_cached" : "unhealthy"), token: nil)
    }
    private func fail(_ error: Error, reload: Bool = false) {
        let apiError = error as? APIError
        denied = denied || [401, 403].contains(apiError?.statusCode ?? 0)
        let changed = ["source_view_changed", "source_view_expired"].contains(apiError?.code ?? "") || (error as? SourceFilterFailure) == .changed
        needsReload = reload || (!changed && [401, 403, 404, 409, 410].contains(apiError?.statusCode ?? 0))
        view += 1; task?.cancel(); task = nil; loading = false
        needsApply = !needsReload; rows = []; healthTask?.cancel()
        self.error = needsReload ? SourceFilterFailure.expired.localizedDescription : changed ? SourceFilterFailure.changed.localizedDescription : error.localizedDescription
        if needsReload { manual += 1 }
    }
    private var query: String { SourceSearch.query(name: title.name, year: title.year, episode: episode.map { ($0.seasonNumber, $0.episodeNumber) }) }
    private func rememberComplete() {
        guard let page, SourceSearch.canExport(page, loaded: rows.count) else { return }
        SourceSearch.remember(title: title, query: query, numbering: episode?.numbering, results: rows.map(\.result), context: context, expiresAt: page.expiresAt, target: page.target)
    }
    private func rememberLegacy(_ rows: [SourceFilterRow]) {
        SourceSearch.remember(title: title, query: query, numbering: episode?.numbering, results: rows.map(\.result), context: context, expiresAt: now().addingTimeInterval(SourceSearch.maxAge))
    }
    private func startHealth() {
        healthTask?.cancel(); let owner = source, wanted = view
        for row in rows { if let health = row.result.health { self.health[row.id] = health } }
        let tokens = Set(rows.compactMap { $0.result.health?.state == "pending" ? $0.result.health?.token : nil } + [page?.sourceHealthToken].compactMap { $0 })
        healthTask = Task { [weak self] in
            guard let self else { return }
            for token in tokens {
                do {
                    var complete = false
                    while !complete && live && owner == source && wanted == view && !Task.isCancelled {
                        let update = try await api.sourceFilterHealth(token: token, context: context)
                        try Task.checkCancellation(); guard current, owner == source, wanted == view else { return }
                        let allowed = Set(rows.map(\.id))
                        for item in update.results where allowed.contains(item.index) { health[item.index] = item.health }
                        complete = update.complete
                    }
                } catch { if !error.isCancellation && current && owner == source && wanted == view && [401, 403].contains((error as? APIError)?.statusCode ?? 0) { fail(error) } }
            }
        }
    }
}
