import Foundation

@MainActor
protocol PostPlayAPI: AnyObject {
    func isCurrent(_ context: SourceActionContext) -> Bool
    func readRating(_ target: DetailsTarget, context: SourceActionContext) async throws -> PersonalTitleRating
    func setRating(_ rating: PersonalTitleRating, target: DetailsTarget, context: SourceActionContext) async throws -> PersonalTitleRating
    func postPlayContext(_ offer: PostPlayOffer) async throws -> PostPlayContextReply
    func postPlaySuggestions(_ offer: PostPlayOffer) async throws -> PostPlaySuggestionsReply
    func postPlaySave(_ title: Title, context: SourceActionContext) async throws
    func postPlayContains(_ title: Title, context: SourceActionContext) async throws -> Bool
    func postPlayDetails(_ title: Title, context: SourceActionContext) async throws -> DetailsBundle
}

extension APIClient: PostPlayAPI {
    static func postPlayRequest(_ offer: PostPlayOffer, suggestions: Bool = false) throws -> URLRequest {
        guard let completed = offer.completion, completed.context == offer.context,
              completed.mediaType == (offer.request.isEpisode ? "episode" : "movie"),
              !completed.itemID.isEmpty, completed.itemID.utf8.count <= 512 else { throw PostPlayFailure.completion }
        let target = offer.request.title
        var request = try offer.context.request("GET", path: "/api/users/\(segment(offer.context.profileID))/post-play/\(target.isMovie ? "movie" : "series")/\(segment(target.titleID))" + (suggestions ? "/recommendations" : ""))
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PostPlayFailure.invalid }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "itemId", value: completed.itemID)]
        request.url = parts.url; request.timeoutInterval = 5; return request
    }
    private func postPlayData(_ request: URLRequest, context: SourceActionContext) async throws -> Data {
        try requireSourceContext(context); try Task.checkCancellation()
        let data = try await sendOriginalSourceAction(request)
        try Task.checkCancellation(); try requireSourceContext(context)
        guard data.count <= 2_097_152 else { throw PostPlayFailure.invalid }; return data
    }
    func postPlayContext(_ offer: PostPlayOffer) async throws -> PostPlayContextReply {
        let data = try await postPlayData(Self.postPlayRequest(offer), context: offer.context)
        let reply = try decoder.decode(PostPlayContextReply.self, from: data); try reply.validate(offer.request.title); return reply
    }
    func postPlaySuggestions(_ offer: PostPlayOffer) async throws -> PostPlaySuggestionsReply {
        let data = try await postPlayData(Self.postPlayRequest(offer, suggestions: true), context: offer.context)
        return try decoder.decode(PostPlaySuggestionsReply.self, from: data)
    }
    func postPlaySave(_ title: Title, context: SourceActionContext) async throws {
        let target = DetailsTarget(title)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target.watchlistUpsert)) as? [String: Any] ?? [:]
        let data = try await postPlayData(context.request("POST", path: "/api/users/\(Self.segment(context.profileID))/watchlist", body: body), context: context)
        let stored = try decoder.decode(WatchlistItem.self, from: data)
        guard WatchlistStore.matches(stored, target) else { throw PostPlayFailure.invalid }
    }
    func postPlayContains(_ title: Title, context: SourceActionContext) async throws -> Bool {
        var request = try context.request("GET", path: "/api/users/\(Self.segment(context.profileID))/display-list")
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PostPlayFailure.invalid }
        parts.queryItems = (parts.queryItems ?? []) + [.init(name: "source", value: "watchlist"), .init(name: "limit", value: "0")]; request.url = parts.url
        let data = try await postPlayData(request, context: context)
        let page = try decoder.decode(DisplayListPage<WatchlistItem>.self, from: data)
        return page.items.contains { WatchlistStore.matches($0, DetailsTarget(title)) }
    }
    func postPlayDetails(_ title: Title, context: SourceActionContext) async throws -> DetailsBundle {
        let target = DetailsTarget(title)
        var query = ["type": target.isMovie ? "movie" : "series", "titleId": target.titleID, "name": target.name]
        query["tmdbId"] = target.tmdbID; query["imdbId"] = target.imdbID; query["tvdbId"] = target.tvdbID; query["year"] = target.year.map(String.init)
        var request = try context.request("GET", path: "/api/users/\(Self.segment(context.profileID))/details-bundle")
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PostPlayFailure.invalid }
        parts.queryItems = (parts.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }; request.url = parts.url
        let data = try await postPlayData(request, context: context)
        return try decoder.decode(DetailsBundle.self, from: data)
    }
}
