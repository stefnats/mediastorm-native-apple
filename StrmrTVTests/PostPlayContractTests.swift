import Foundation
import XCTest
@testable import StrmrTV

@MainActor
enum PostPlayFixture {
    static func context(_ profile: String = "original") -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://synthetic.invalid/proxy")!, profileID: profile, clientID: "synthetic-client", sessionToken: "synthetic-session", unlock: "synthetic-proof")
    }
    static func decode<T: Decodable>(_ raw: Any, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: raw))
    }
    static func title(_ id: Int = 1, series: Bool = false, lifecycle: String? = nil) throws -> Title {
        var raw: [String: Any] = ["id": "tmdb:\(series ? "series" : "movie"):\(id)", "name": "Synthetic \(id)", "mediaType": series ? "series" : "movie", "tmdbId": id]
        if let lifecycle { raw["lifecycleStatus"] = lifecycle }; return try decode(raw)
    }
    static func episode(_ number: Int = 1, future: Bool = false) throws -> Episode {
        try decode(["id": "episode-\(number)", "itemId": "stored-original-\(number)", "name": "Episode \(number)", "seasonNumber": 1, "episodeNumber": number,
            "airedDate": future ? "2099-01-01" : "2020-01-01", "numbering": ["seriesId": "tmdb:series:1", "ordering": "official"]])
    }
    static func request(series: Bool = false, episodes: [Episode]? = nil, selected: Episode? = nil, lifecycle: String? = nil) throws -> PlaybackRequest {
        let title = try Self.title(series: series, lifecycle: lifecycle)
        let episodes = try episodes ?? (series ? [Self.episode()] : [])
        let seasons = series ? [Season(id: "season-one", name: "Season 1", number: 1, episodes: episodes)] : []
        return DetailsRequest.make(target: DetailsTarget(title), title: title, seasons: seasons, episode: selected ?? episodes.first,
            start: nil, seed: 1, library: nil)
    }
    static func offer(series: Bool = false, completed: Bool = true) throws -> PostPlayOffer {
        let request = try Self.request(series: series), context = Self.context()
        return PostPlayOffer(id: UUID(), request: request, context: context,
            completion: completed ? PostPlayCompletion(context: context, itemID: series ? "canonical-stored-episode" : request.title.titleID, mediaType: series ? "episode" : "movie") : nil)
    }
    static func contextReply(series: Bool = false, rating: PersonalTitleRating = .none) throws -> PostPlayContextReply {
        PostPlayContextReply(title: try title(series: series), rating: rating, ratingScope: series ? "series" : "movie", completion: series ? "episode" : "movie")
    }
    static func suggestions(rating: PersonalTitleRating = .none, source: String = "personalized", ids: [Int] = [2]) throws -> PostPlaySuggestionsReply {
        PostPlaySuggestionsReply(items: try ids.enumerated().map { TrendingItem(rank: $0.offset + 1, title: try title($0.element)) },
            total: ids.count, source: source, rating: rating, ratingScope: "movie")
    }
}

@MainActor
final class PostPlayContractTests: XCTestCase {
    func testActualGoContextAndSuggestionsSchemaUsesExistingRating() throws {
        let title: [String: Any] = ["id": "tmdb:movie:1", "mediaType": "movie", "name": "Synthetic", "tmdbId": 1]
        let reply: PostPlayContextReply = try PostPlayFixture.decode(["title": title, "rating": "love", "ratingScope": "movie", "completion": "movie"])
        try reply.validate(DetailsTarget(PostPlayFixture.title()))
        XCTAssertEqual(reply.rating, .love)
        let suggestions: PostPlaySuggestionsReply = try PostPlayFixture.decode(["items": [], "total": 0, "source": "unavailable", "rating": "love", "ratingScope": "movie"])
        XCTAssertNoThrow(try suggestions.validate(target: DetailsTarget(PostPlayFixture.title()), rating: .love))
    }
    func testCanonicalCompletedEpisodeIdentityIsPassedVerbatimWithoutReconstruction() throws {
        let offer = try PostPlayFixture.offer(series: true)
        let request = try APIClient.postPlayRequest(offer)
        XCTAssertEqual(request.url?.path, "/proxy/api/users/original/post-play/series/tmdb:series:1")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "itemId" })?.value, "canonical-stored-episode")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Unlock"), "synthetic-proof")
        XCTAssertFalse(request.url!.absoluteString.contains("S01E01"))
    }
    func testUnknownCompletionCannotMintAContextRead() throws {
        XCTAssertThrowsError(try APIClient.postPlayRequest(PostPlayFixture.offer(completed: false)))
        let original = try PostPlayFixture.offer()
        let wrong = PostPlayOffer(id: UUID(), request: original.request, context: original.context,
            completion: PostPlayCompletion(context: PostPlayFixture.context("replacement"), itemID: "foreign", mediaType: "movie"))
        XCTAssertThrowsError(try APIClient.postPlayRequest(wrong))
    }
    func testEpisodeCompletionLabelsWholeSeriesWithoutClaimingSeriesEnd() throws {
        let reply = try PostPlayFixture.contextReply(series: true)
        try reply.validate(DetailsTarget(PostPlayFixture.title(series: true)))
        XCTAssertEqual(reply.completion, "episode"); XCTAssertEqual(reply.ratingScope, "series")
        XCTAssertFalse(try PostPlayFixture.request(series: true).postPlayStamp!.seriesEnded)
    }
    func testWrongScopeKindAndCompletionAreRejected() throws {
        let title = try PostPlayFixture.title()
        for reply in [PostPlayContextReply(title: title, rating: .none, ratingScope: "series", completion: "movie"),
                      PostPlayContextReply(title: title, rating: .none, ratingScope: "movie", completion: "episode")] {
            XCTAssertThrowsError(try reply.validate(DetailsTarget(title)))
        }
    }
    func testSuggestionsRequireCurrentRatingScopeAndBoundedUnavailableSource() throws {
        let target = DetailsTarget(try PostPlayFixture.title())
        XCTAssertThrowsError(try PostPlayFixture.suggestions(rating: .like).validate(target: target, rating: .dislike))
        XCTAssertThrowsError(try PostPlayFixture.suggestions(source: "unavailable").validate(target: target, rating: .none))
        XCTAssertThrowsError(try PostPlayFixture.suggestions(source: "external_fallback").validate(target: target, rating: .none))
        XCTAssertNoThrow(try PostPlayFixture.suggestions(source: "saved_choices").validate(target: target, rating: .none))
    }
    func testCurrentDuplicateDislikedAndMoreThanSixOfOneKindAreRejected() throws {
        let target = DetailsTarget(try PostPlayFixture.title())
        for ids in [[1], [2, 2], Array(2...8)] { XCTAssertThrowsError(try PostPlayFixture.suggestions(ids: ids).validate(target: target, rating: .none)) }
        var disliked = try PostPlayFixture.title(2); disliked.personalRating = "dislike"
        let reply = PostPlaySuggestionsReply(items: [TrendingItem(rank: 1, title: disliked)], total: 1, source: "saved_choices", rating: .none, ratingScope: "movie")
        XCTAssertThrowsError(try reply.validate(target: target, rating: .none))
    }
    func testSeriesStampUsesActualLifecycleOrderingAndFutureMetadata() throws {
        let first = try PostPlayFixture.episode(), future = try PostPlayFixture.episode(2, future: true)
        let caughtUp = try PostPlayFixture.request(series: true, episodes: [first, future], selected: first, lifecycle: "Continuing")
        XCTAssertNil(caughtUp.nextEpisode); XCTAssertEqual(caughtUp.postPlayStamp?.upcoming?.id, future.id); XCTAssertFalse(caughtUp.postPlayStamp!.seriesEnded)
        let ended = try PostPlayFixture.request(series: true, lifecycle: "Ended")
        XCTAssertTrue(ended.postPlayStamp!.seriesEnded)
        let missing = try PostPlayFixture.request(series: true, episodes: [first], selected: PostPlayFixture.episode(7), lifecycle: "Ended")
        XCTAssertFalse(missing.postPlayStamp!.orderingKnown); XCTAssertFalse(missing.postPlayStamp!.seriesEnded)
    }
    func testActualNextEpisodeConstructorPreservesKnownFinalSeriesStamp() throws {
        let first = try PostPlayFixture.episode(), second = try PostPlayFixture.episode(2)
        let original = try PostPlayFixture.request(series: true, episodes: [first, second], selected: first, lifecycle: "Ended")
        let next = try XCTUnwrap(original.nextEpisode)
        XCTAssertEqual(next.episode?.episode, 2); XCTAssertNil(next.nextEpisode)
        XCTAssertTrue(next.postPlayStamp!.orderingKnown); XCTAssertTrue(next.postPlayStamp!.seriesEnded)
    }
    func testExistingProgressReplyKeepsMigrationAndActualCanonicalFields() throws {
        let reply: ProgressReply = try PostPlayFixture.decode(["itemId": "server-canonical", "mediaType": "episode", "migrationRequested": true, "migrationReason": "synthetic"])
        XCTAssertEqual(reply.itemId, "server-canonical"); XCTAssertEqual(reply.mediaType, "episode"); XCTAssertEqual(reply.migrationRequested, true)
        let legacy: ProgressReply = try PostPlayFixture.decode(["migrationRequested": false])
        XCTAssertNil(legacy.itemId)
    }
}
