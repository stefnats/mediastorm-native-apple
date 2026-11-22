import Foundation

/// The ranked sources for one playback, in the details page's source picker's order
/// (`SourceSearch`): the picker's own results for this title / episode when it searched
/// recently, so the two lists match, else a search with the same call. Pending cache /
/// health checks resolve in the background, so a later visit shows them.
@MainActor
final class SourceSwitchList {
    private(set) var results: [SourceResult] = []
    private(set) var health: [Int: SourceHealth] = [:]
    private var search: Task<Result<[SourceResult], Error>, Never>?
    private var healthTask: Task<Void, Never>?
    private let request: PlaybackRequest
    private let context: SourceActionContext
    private var closed = false
    private var resultsExpireAt: Date?

    init(request: PlaybackRequest) {
        self.request = request
        context = APIClient.shared.sourceContext()
    }

    private var query: String {
        SourceSearch.query(name: request.title.name, year: request.title.year,
                           episode: request.episode.map { ($0.season, $0.episode) })
    }

    private var numbering: EpisodeNumbering? { request.episode?.numbering }

    func cancel() {
        closed = true; results = []; health = [:]
        search?.cancel()
        healthTask?.cancel()
    }

    /// The picker's recent results, else searches the first time (a failed search is
    /// retried on the next call).
    func load() async throws -> [SourceResult] {
        try APIClient.shared.requireSourceContext(context); guard !closed else { throw CancellationError() }
        if let expires = resultsExpireAt, Date() >= expires {
            results = []; health = [:]; search = nil; healthTask?.cancel(); resultsExpireAt = nil
        }
        if results.isEmpty, let recent = SourceSearch.recent(title: request.title, query: query, numbering: numbering) {
            results = recent.results
            health = recent.health; resultsExpireAt = recent.expiresAt
            return results
        }
        if search == nil {
            let title = request.title
            let query = query
            let numbering = numbering
            search = Task {
                do { return .success(try await SourceSearch.search(title: title, query: query, numbering: numbering, context: context)) } catch { return .failure(error) }
            }
        }
        let reply = await search!.value
        try Task.checkCancellation(); try APIClient.shared.requireSourceContext(context)
        guard !closed else { throw CancellationError() }
        switch reply {
        case let .success(results):
            if self.results.isEmpty, !results.isEmpty { adopt(results) }
            return self.results
        case let .failure(error):
            search = nil
            throw error
        }
    }

    private func adopt(_ results: [SourceResult]) {
        self.results = results
        resultsExpireAt = Date().addingTimeInterval(SourceSearch.maxAge)
        health = SourceSearch.initialHealth(results)
        let tokens = Set(health.values.filter { $0.state == "pending" }.compactMap(\.token))
        guard !tokens.isEmpty else { return }
        let title = request.title
        let query = query
        let numbering = numbering
        let context = context
        healthTask = Task { [weak self] in
            for token in tokens {
                var complete = false
                while !complete, !Task.isCancelled {
                    guard let snapshot = try? await APIClient.shared.sourceFilterHealth(token: token, context: context) else { break }
                    guard let self, !closed, APIClient.shared.isCurrent(context), !Task.isCancelled else { return }
                    for entry in snapshot.results where results.contains(where: { $0.index == entry.index }) {
                        self.health[entry.index] = entry.health
                        SourceSearch.updateHealth(title: title, query: query, numbering: numbering, index: entry.index, health: entry.health, context: context, snapshotID: results.first?.snapshotID)
                    }
                    complete = snapshot.complete
                }
            }
        }
    }
}
