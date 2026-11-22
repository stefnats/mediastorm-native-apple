import Foundation

/// The manual source list's search, order and health, shared by the details page's source
/// picker and the player's Switch Source list, so the two show the same
/// sources in the same order.
///
/// Both lists used to run their own `/api/indexers/search`, minutes apart: the indexers, the
/// remembered usenet health and the adaptive caps can change between the two, so the
/// server's ranking (and its order among equal ranks) came back different. Now the picker's
/// latest results are kept per title / episode, and Switch Source shows those, in the same
/// `ordered` order with the same health; it searches itself only when the picker hasn't
/// searched in the last `maxAge`.
@MainActor
enum SourceSearch {
    struct Key: Hashable {
        let titleID: String
        let query: String
        /// The episode's ordering: "S01E02" is a different episode in each.
        var ordering: String? = nil
        var numberingID: String? = nil
    }

    struct Snapshot {
        var results: [SourceResult]
        var health: [Int: SourceHealth]
        let at: Date
        let context: SourceActionContext
        let expiresAt: Date
        let target: SourceFilterTarget?
    }

    /// How long a search is reused by Switch Source.
    static let maxAge: TimeInterval = 30 * 60
    private static var snapshots: [Key: Snapshot] = [:]

    /// The search query ("Name S01E02", or "Name 2024").
    nonisolated static func query(name: String, year: Int?, episode: (season: Int, episode: Int)?) -> String {
        if let episode { return name + String(format: " S%02dE%02d", episode.season, episode.episode) }
        if let year { return "\(name) \(year)" }
        return name
    }

    /// The list's order: the server's rank (its response order), the one order both lists use.
    nonisolated static func ordered(_ results: [SourceResult]) -> [SourceResult] {
        results.sorted { $0.index < $1.index }
    }

    /// The health a result starts with: the search's own annotation.
    nonisolated static func initialHealth(_ results: [SourceResult]) -> [Int: SourceHealth] {
        Dictionary(results.compactMap { r in r.health.map { (r.index, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Searches and keeps the results for this title / episode (the source picker, and
    /// Switch Source when nothing recent is kept).
    static func search(title: DetailsTarget, query: String, numbering: EpisodeNumbering? = nil,
                       context original: SourceActionContext? = nil) async throws -> [SourceResult] {
        let context = original ?? APIClient.shared.sourceContext()
        let results = ordered(try await APIClient.shared.originalLegacySourceSearch(title: title, query: query, numbering: numbering, context: context))
        try APIClient.shared.requireSourceContext(context); try Task.checkCancellation()
        remember(title: title, query: query, numbering: numbering, results: results, context: context, expiresAt: Date().addingTimeInterval(maxAge))
        return results
    }

    static func retire(title: DetailsTarget, query: String, numbering: EpisodeNumbering?, context: SourceActionContext) {
        let key = Key(titleID: title.titleID, query: query, ordering: numbering?.ordering, numberingID: numbering?.seriesId)
        guard APIClient.shared.isCurrent(context), snapshots[key]?.context == context else { return }; snapshots[key] = nil
    }

    static func canExport(_ page: SourceFilterPage, loaded: Int) -> Bool {
        !page.filters.active && page.nextCursor == nil && loaded == page.total
    }

    /// Only complete unfiltered views are exported. A filtered page or a first
    /// finite page with a cursor is never advertised as the complete source set.
    static func remember(title: DetailsTarget, query: String, numbering: EpisodeNumbering?, results: [SourceResult], context: SourceActionContext, expiresAt: Date, target: SourceFilterTarget? = nil) {
        guard APIClient.shared.isCurrent(context), target == nil || (target?.titleId == title.titleID && target?.mediaType == (title.isMovie ? "movie" : "series")) else { return }
        snapshots[Key(titleID: title.titleID, query: query, ordering: numbering?.ordering, numberingID: numbering?.seriesId)] =
            Snapshot(results: results, health: initialHealth(results), at: Date(), context: context, expiresAt: expiresAt, target: target)
    }

    /// The results kept for this title / episode, if recent enough.
    static func recent(title: DetailsTarget, query: String, numbering: EpisodeNumbering? = nil,
                       now: Date = Date()) -> Snapshot? {
        guard let snapshot = snapshots[Key(titleID: title.titleID, query: query, ordering: numbering?.ordering, numberingID: numbering?.seriesId)],
              now.timeIntervalSince(snapshot.at) < maxAge, now < snapshot.expiresAt, APIClient.shared.isCurrent(snapshot.context) else { return nil }
        return snapshot
    }

    /// Records a result's latest health (a resolved check or a probe), so the other list
    /// shows it too.
    static func updateHealth(title: DetailsTarget, query: String, numbering: EpisodeNumbering? = nil,
                             index: Int, health: SourceHealth, context: SourceActionContext? = nil, snapshotID: String? = nil) {
        let key = Key(titleID: title.titleID, query: query, ordering: numbering?.ordering, numberingID: numbering?.seriesId)
        guard let snapshot = snapshots[key], APIClient.shared.isCurrent(snapshot.context), Date() < snapshot.expiresAt,
              context == nil || context == snapshot.context, snapshot.results.first?.snapshotID == snapshotID else { return }
        snapshots[key]?.health[index] = health
    }
}
