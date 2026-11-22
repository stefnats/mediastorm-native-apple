import Foundation

/// Only release-retry resources in this process. This coordinates deduplicated
/// prequeue IDs; it grants no playback, session or profile authority.
@MainActor
final class ReleaseReplacementOwnership {
    static let shared = ReleaseReplacementOwnership()
    fileprivate struct Key: Hashable { let server: URL; let original: String }
    private final class Record {
        var pending = Set<UUID>()
        var owners: [String: Set<UUID>] = [:]
        var requested: [String: (any ReleaseReportAPI, SourceActionContext)] = [:]
        var deleting: [String: Task<Void, Never>] = [:]
        var uncertain = false
    }

    @MainActor
    final class Request {
        fileprivate let key: Key
        fileprivate let token = UUID()
        fileprivate var finished = false
        fileprivate init(_ key: Key) { self.key = key }
    }

    @MainActor
    final class Lease: Equatable {
        nonisolated let identity = UUID()
        nonisolated static func == (lhs: Lease, rhs: Lease) -> Bool { lhs.identity == rhs.identity }
        let id: String
        fileprivate let key: Key
        fileprivate let api: any ReleaseReportAPI
        fileprivate let context: SourceActionContext
        fileprivate var released = false
        private let owner: ReleaseReplacementOwnership
        fileprivate init(id: String, key: Key, api: any ReleaseReportAPI,
                         context: SourceActionContext, owner: ReleaseReplacementOwnership) {
            self.id = id; self.key = key; self.api = api; self.context = context; self.owner = owner
        }
        func release() async throws { try await owner.release(self) }
    }

    private var records: [Key: Record] = [:]
    private let limit = 64
    var retainedOriginals: Int { records.count }

    func begin(original: String, context: SourceActionContext) async throws -> Request {
        let key = Key(server: context.baseURL, original: original)
        while let record = records[key], !record.deleting.isEmpty {
            let pending = Array(record.deleting.values)
            for deletion in pending { await deletion.value }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        if records[key]?.uncertain == true { throw uncertainError() }
        guard records[key] != nil || records.count < limit else {
            throw APIError.notReady("Too many source changes still need cleanup. Close existing playback before trying another source.")
        }
        let record = records[key] ?? Record()
        records[key] = record
        let request = Request(key)
        record.pending.insert(request.token)
        return request
    }

    func needsCleanupRetry(original: String, context: SourceActionContext) -> Bool {
        records[Key(server: context.baseURL, original: original)]?.uncertain == true
    }

    func retryCleanup(original: String, context: SourceActionContext) async throws {
        let key = Key(server: context.baseURL, original: original)
        guard let record = records[key], record.uncertain else { return }
        guard record.pending.isEmpty, record.owners.isEmpty, record.deleting.isEmpty else {
            throw APIError.notReady("The alternative is still in use. Close that playback before retrying cancellation.")
        }
        // Explicit user retry, using the held original cleanup context. Do not
        // forget an unknown DELETE on a timer and allow a racing new POST.
        record.uncertain = false
        sweep(key)
        let pending = records[key].map { Array($0.deleting.values) } ?? []
        for task in pending { await task.value }
        if records[key]?.uncertain == true { throw uncertainError() }
    }

    func adopt(_ id: String, request: Request, api: any ReleaseReportAPI,
               context: SourceActionContext) throws -> Lease {
        guard !request.finished, let record = records[request.key], record.pending.contains(request.token), !id.isEmpty else {
            throw APIError.notReady("The alternative no longer has an active request owner")
        }
        let lease = Lease(id: id, key: request.key, api: api, context: context, owner: self)
        record.owners[id, default: []].insert(lease.identity)
        return lease
    }

    func finish(_ request: Request) {
        guard !request.finished else { return }
        request.finished = true
        records[request.key]?.pending.remove(request.token)
        sweep(request.key)
    }

    private func release(_ lease: Lease) async throws {
        guard !lease.released else { return }
        lease.released = true
        guard let record = records[lease.key] else { return }
        record.owners[lease.id]?.remove(lease.identity)
        if record.owners[lease.id]?.isEmpty == true { record.owners[lease.id] = nil }
        record.requested[lease.id] = (lease.api, lease.context)
        sweep(lease.key)
        if let deletion = records[lease.key]?.deleting[lease.id] { await deletion.value }
        if records[lease.key]?.uncertain == true { throw uncertainError() }
    }

    private func sweep(_ key: Key) {
        guard let record = records[key] else { return }
        if record.pending.isEmpty && !record.uncertain {
            for (id, cleanup) in record.requested where record.owners[id]?.isEmpty != false && record.deleting[id] == nil {
                // Reserve deletion before launching its task. A new POST for
                // this original ID waits for the actual DELETE completion.
                record.deleting[id] = Task { [self] in
                    var known = false
                    do { try await cleanup.0.cancelReleaseReplacement(id, context: cleanup.1); known = true }
                    catch { }
                    guard let current = records[key] else { return }
                    current.deleting[id] = nil
                    if known { current.requested[id] = nil }
                    else { current.uncertain = true }
                    removeIfFinished(key)
                }
            }
        }
        removeIfFinished(key)
    }

    private func removeIfFinished(_ key: Key) {
        guard let record = records[key], !record.uncertain, record.pending.isEmpty,
              record.owners.isEmpty, record.requested.isEmpty, record.deleting.isEmpty else { return }
        records[key] = nil
    }

    private func uncertainError() -> APIError {
        APIError.notReady("The previous alternative cancellation was not confirmed. Retry cancellation explicitly, or start fresh playback before preparing another alternative from this source.")
    }
}
