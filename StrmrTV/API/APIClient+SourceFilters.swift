import Foundation

@MainActor
protocol SourceFilterAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func isCurrent(_ context: SourceActionContext) -> Bool
    func sourceFilterSearch(title: DetailsTarget, episode: Episode?, context: SourceActionContext) async throws -> SourceFilterReply
    func sourceFilterPage(snapshot: String, filters: SourceFilters, cursor: String?, context: SourceActionContext) async throws -> SourceFilterPage
    func sourceFilterHealth(token: String, context: SourceActionContext) async throws -> SourceHealthSnapshot
    func probeTracks(_ result: SourceResult, context: SourceActionContext) async throws -> SourceTrackProbe
}

extension APIClient: SourceFilterAPI {
    private static let sourceFilterProbeHTTP: URLSession = {
        let config = sourceActionConfiguration()
        config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    static func sourceFilterQuery(title: DetailsTarget, episode: Episode?, context: SourceActionContext) throws -> [String: String] {
        let target = SourceFilterTarget(title: title, episode: episode); try target.validate()
        var query = ["q": SourceSearch.query(name: title.name, year: title.year, episode: episode.map { ($0.seasonNumber, $0.episodeNumber) }),
            "titleId": target.titleId, "mediaType": target.mediaType, "userId": context.profileID, "includeSourceHealth": "true", "limit": "50", "sourceFiltersVersion": "1"]
        if let imdb = title.imdbID { query["imdbId"] = imdb }; if let year = title.year { query["year"] = String(year) }
        if let episode = target.episode {
            query["episodeId"] = episode.episodeId; query["seasonNumber"] = String(episode.seasonNumber); query["episodeNumber"] = String(episode.episodeNumber)
            if let numbering = episode.numbering { query["episodeNumberingId"] = numbering.seriesId; query["episodeOrdering"] = numbering.ordering }
        }
        return query
    }
    static func sourceFilterPageBody(filters: SourceFilters, cursor: String?, limit: Int = 50) throws -> [String: Any] {
        guard (1...100).contains(limit) else { throw SourceFilterFailure.invalid }
        var body: [String: Any] = ["version": 1, "filters": try filters.body(), "limit": limit]
        if let cursor { body["cursor"] = try SourceFilterWire.text(cursor) }; return body
    }
    static func sourceFilterRequest(_ context: SourceActionContext, method: String, path: String, query: [String: String] = [:], body: [String: Any]? = nil) throws -> URLRequest {
        var request = try context.request(method, path: path, body: body)
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw SourceFilterFailure.invalid }
        var values = query; values["profileId"] = context.profileID
        parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.url = parts.url; guard request.url != nil else { throw SourceFilterFailure.invalid }; return request
    }
    func sourceFilterData(_ request: URLRequest, context: SourceActionContext) async throws -> Data {
        try requireSourceContext(context); try Task.checkCancellation()
        // Existing original-request transport has an actual 30-second resource
        // deadline and no refresh/rebase/replay. The decoded envelope is finite;
        // this post-read size check is not a streaming memory-bound claim.
        let data = try await sendOriginalSourceAction(request)
        try Task.checkCancellation(); try requireSourceContext(context)
        guard data.count <= 8_388_608 else { throw SourceFilterFailure.invalid }; return data
    }
    /// Keep the existing manual probe's 90-second budget on its actual
    /// original-request resource; ordinary snapshot pages retain 30 seconds.
    func sourceFilterProbeData(_ original: URLRequest, context: SourceActionContext) async throws -> Data {
        try requireSourceContext(context); try Task.checkCancellation()
        var request = original; request.timeoutInterval = 90
        let (data, response) = try await Self.sourceFilterProbeHTTP.data(for: request)
        try Task.checkCancellation(); try requireSourceContext(context)
        guard let response = response as? HTTPURLResponse else { throw SourceFilterFailure.invalid }
        guard (200..<300).contains(response.statusCode) else { throw APIError.http(HTTPFailure(status: response.statusCode, data: data, headers: response.allHeaderFields)) }
        guard data.count <= 8_388_608 else { throw SourceFilterFailure.invalid }; return data
    }
    func sourceFilterSearch(title: DetailsTarget, episode: Episode?, context: SourceActionContext) async throws -> SourceFilterReply {
        var request = try Self.sourceFilterRequest(context, method: "GET", path: "/api/indexers/search", query: Self.sourceFilterQuery(title: title, episode: episode, context: context))
        for (key, value) in AdaptiveThroughput.shared.requestHeaders() { request.setValue(value, forHTTPHeaderField: key) }
        let data = try await sourceFilterData(request, context: context)
        return try SourceFilterWire.initial(data)
    }
    func sourceFilterPage(snapshot: String, filters: SourceFilters, cursor: String?, context: SourceActionContext) async throws -> SourceFilterPage {
        let snapshot = try SourceFilterWire.text(snapshot)
        let request = try Self.sourceFilterRequest(context, method: "POST", path: "/api/users/\(Self.segment(context.profileID))/source-searches/\(Self.segment(snapshot))/page", body: Self.sourceFilterPageBody(filters: filters, cursor: cursor))
        let data = try await sourceFilterData(request, context: context)
        return try SourceFilterWire.page(JSONSerialization.jsonObject(with: data))
    }
    func sourceFilterHealth(token: String, context: SourceActionContext) async throws -> SourceHealthSnapshot {
        let request = try Self.sourceFilterRequest(context, method: "GET", path: "/api/indexers/source-health", query: ["token": SourceFilterWire.text(token), "waitMs": "20000"])
        let data = try await sourceFilterData(request, context: context)
        return try decoder.decode(SourceHealthSnapshot.self, from: data)
    }
    /// Switch Source retains an explicit old-server search when no complete
    /// original-context picker snapshot exists. Episode IDs are never invented.
    func originalLegacySourceSearch(title: DetailsTarget, query: String, numbering: EpisodeNumbering?, context: SourceActionContext) async throws -> [SourceResult] {
        var q = ["q": query, "titleId": title.titleID, "mediaType": title.isMovie ? "movie" : "series", "userId": context.profileID, "includeSourceHealth": "true", "limit": "50"]
        q["imdbId"] = title.imdbID; q["year"] = title.year.map(String.init)
        if let numbering { q["episodeNumberingId"] = numbering.seriesId; q["episodeOrdering"] = numbering.ordering }
        var request = try Self.sourceFilterRequest(context, method: "GET", path: "/api/indexers/search", query: q)
        for (key, value) in AdaptiveThroughput.shared.requestHeaders() { request.setValue(value, forHTTPHeaderField: key) }
        let raw = try await sourceFilterData(request, context: context)
        guard case let .legacy(rows) = try SourceFilterWire.initial(raw) else { throw SourceFilterFailure.invalid }
        return rows.map(\.result)
    }
}
