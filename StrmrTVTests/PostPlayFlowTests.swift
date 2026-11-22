import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class PostPlayFixtureAPI: PostPlayAPI {
    var context = PostPlayFixture.context()
    var rating = PersonalTitleRating.none
    var calls: [String] = []
    var suggestionsSource = "personalized"
    var suggestionsReply: PostPlaySuggestionsReply?
    var detailsReply: DetailsBundle?
    var holdDetails = false
    var pendingDetails: [Int: CheckedContinuation<DetailsBundle, Error>] = [:]
    private var detailsIndex = 0
    var contextError: Error?
    var suggestionsError: Error?
    var ratingError: Error?
    var listError: Error?
    var member = false
    var holdSuggestions = false
    var pendingSuggestions: CheckedContinuation<PostPlaySuggestionsReply, Error>?
    var holdRating = false
    var pendingRating: CheckedContinuation<PersonalTitleRating, Error>?
    var holdList = false
    var pendingList: CheckedContinuation<Void, Error>?
    func isCurrent(_ context: SourceActionContext) -> Bool { self.context == context }
    func readRating(_ target: DetailsTarget, context: SourceActionContext) async throws -> PersonalTitleRating { calls.append("read-rating"); return rating }
    func setRating(_ value: PersonalTitleRating, target: DetailsTarget, context: SourceActionContext) async throws -> PersonalTitleRating {
        calls.append("rate:" + value.rawValue)
        if let ratingError { throw ratingError }
        if holdRating { return try await withCheckedThrowingContinuation { pendingRating = $0 } }
        rating = value; return value
    }
    func postPlayContext(_ offer: PostPlayOffer) async throws -> PostPlayContextReply {
        calls.append("context"); if let contextError { throw contextError }; return try PostPlayFixture.contextReply(rating: rating)
    }
    func postPlaySuggestions(_ offer: PostPlayOffer) async throws -> PostPlaySuggestionsReply {
        calls.append("suggestions:" + rating.rawValue)
        if let suggestionsError { throw suggestionsError }
        if let suggestionsReply { return suggestionsReply }
        if holdSuggestions { return try await withCheckedThrowingContinuation { pendingSuggestions = $0 } }
        return try PostPlayFixture.suggestions(rating: rating, source: suggestionsSource, ids: suggestionsSource == "unavailable" ? [] : [2])
    }
    func postPlaySave(_ title: Title, context: SourceActionContext) async throws {
        calls.append("save:" + title.id)
        if let listError { throw listError }
        if holdList { return try await withCheckedThrowingContinuation { pendingList = $0 } }; member = true
    }
    func postPlayContains(_ title: Title, context: SourceActionContext) async throws -> Bool { calls.append("contains:" + title.id); return member }
    func postPlayDetails(_ title: Title, context: SourceActionContext) async throws -> DetailsBundle {
        calls.append("details:" + title.id)
        if holdDetails {
            let index = detailsIndex; detailsIndex += 1
            return try await withCheckedThrowingContinuation { pendingDetails[index] = $0 }
        }
        if let detailsReply { return detailsReply }
        return try PostPlayFixture.decode(["movieDetails": ["id": title.id, "name": title.name, "mediaType": title.mediaType, "tmdbId": title.tmdbId ?? 0], "resume": ["position": 30, "duration": 120, "percent": 25, "eligible": true]])
    }
}

@MainActor
final class PostPlayFlowTests: XCTestCase {
    func until(_ predicate: () -> Bool) async { for _ in 0..<1000 where !predicate() { await Task.yield() } }
    func ready(_ api: PostPlayFixtureAPI) async throws -> PostPlayModel {
        let model = PostPlayModel(offer: try PostPlayFixture.offer(), api: api)
        model.load(); await until { !model.loading }; return model
    }
    func testOpenShowsCurrentRatingAndSuggestionsWithoutWritingOrPreparing() async throws {
        let api = PostPlayFixtureAPI(); api.rating = .love
        let model = try await ready(api); defer { model.close() }
        XCTAssertEqual(model.rating, .love); XCTAssertFalse(model.question); XCTAssertEqual(model.suggestions.count, 1)
        XCTAssertEqual(api.calls, ["context", "suggestions:love"])
    }
    func testYesAndNoUseExistingRatingThenRequireFreshRecommendationEcho() async throws {
        for value in [PersonalTitleRating.like, .dislike] {
            let api = PostPlayFixtureAPI(), model = try await ready(api)
            model.rate(value); await until { !model.saving }
            XCTAssertEqual(api.calls, ["context", "suggestions:none", "rate:" + value.rawValue, "suggestions:" + value.rawValue])
            XCTAssertEqual(model.rating, value); XCTAssertFalse(model.question); model.close()
        }
    }
    func testSkipDoesNotWriteAndExplicitReloadDoesNotReaskSameQuestion() async throws {
        let api = PostPlayFixtureAPI(), model = try await ready(api); defer { model.close() }
        XCTAssertTrue(model.question); model.skip(); model.load(); await until { !model.loading }
        XCTAssertFalse(model.question); XCTAssertFalse(api.calls.contains(where: { $0.hasPrefix("rate:") }))
    }
    func testLostDislikeAcknowledgementClearsPositiveSuggestionsUntilExplicitRead() async throws {
        let api = PostPlayFixtureAPI(), model = try await ready(api); defer { model.close() }
        api.ratingError = URLError(.networkConnectionLost); model.rate(.dislike); await until { !model.saving }
        XCTAssertNil(model.rating); XCTAssertTrue(model.suggestions.isEmpty)
        model.rate(.like); XCTAssertEqual(api.calls.filter { $0.hasPrefix("rate:") }.count, 1)
        api.rating = .dislike; api.ratingError = nil; model.load(); await until { !model.loading }
        XCTAssertEqual(model.rating, .dislike); XCTAssertEqual(api.calls.last, "suggestions:dislike")
    }
    func testOldPositiveRecommendationReplyCannotSurviveViewerChange() async throws {
        let api = PostPlayFixtureAPI(); api.holdSuggestions = true
        let model = PostPlayModel(offer: try PostPlayFixture.offer(), api: api); defer { model.close() }
        model.load(); await until { api.pendingSuggestions != nil }
        api.context = PostPlayFixture.context("replacement")
        api.pendingSuggestions?.resume(returning: try PostPlayFixture.suggestions()); api.pendingSuggestions = nil
        await until { !model.loading }
        XCTAssertTrue(model.suggestions.isEmpty); XCTAssertFalse(model.current); model.rate(.like)
        XCTAssertFalse(api.calls.contains("rate:like"))
    }
    func testServerSavedChoicesAndUnavailableFallbackDoNotCallClientSimilarSearch() async throws {
        for source in ["saved_choices", "unavailable"] {
            let api = PostPlayFixtureAPI(); api.suggestionsSource = source
            let model = try await ready(api); defer { model.close() }
            XCTAssertEqual(model.suggestionsSource, source); XCTAssertEqual(model.suggestions.count, source == "unavailable" ? 0 : 1)
            XCTAssertEqual(api.calls.count, 2)
        }
    }
    func testSuggestionFailureKeepsKnownRatingAndNoStaleCandidateFallback() async throws {
        let api = PostPlayFixtureAPI(); api.rating = .dislike; api.suggestionsError = URLError(.notConnectedToInternet)
        let model = try await ready(api); defer { model.close() }
        XCTAssertEqual(model.rating, .dislike); XCTAssertTrue(model.suggestions.isEmpty); XCTAssertNotNil(model.suggestionsError)
    }
    func testUnknownListAcknowledgementUsesReadbackBeforeAnotherWrite() async throws {
        let api = PostPlayFixtureAPI(), model = try await ready(api); defer { model.close() }
        let row = try XCTUnwrap(model.suggestions.first)
        api.listError = URLError(.networkConnectionLost); model.save(row); await until { model.listSaving.isEmpty }
        XCTAssertTrue(model.uncertainSaves.contains(row.id))
        api.member = true; model.save(row); await until { model.listSaving.isEmpty }
        XCTAssertTrue(model.saved.contains(row.id)); XCTAssertEqual(api.calls.filter { $0.hasPrefix("save:") }.count, 1)
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("contains:") }.count, 1)
    }
    func testOutstandingListWriteCannotBeLostByConcurrentRatingRefresh() async throws {
        let api = PostPlayFixtureAPI(), model = try await ready(api); defer { model.close() }
        api.holdList = true; let row = try XCTUnwrap(model.suggestions.first)
        model.save(row); await until { api.pendingList != nil }; model.rate(.dislike); model.load()
        XCTAssertEqual(api.calls.filter { $0 == "context" }.count, 1); XCTAssertFalse(api.calls.contains("rate:dislike"))
        api.pendingList?.resume(); api.pendingList = nil; await until { model.listSaving.isEmpty }
        XCTAssertTrue(model.saved.contains(row.id))
    }
    func testCopiedCandidateAndClosedViewCannotSaveNavigateOrPlay() async throws {
        let api = PostPlayFixtureAPI(), model = try await ready(api)
        let row = try XCTUnwrap(model.suggestions.first), copy = PostPlaySuggestion(row.title)
        XCTAssertNil(model.details(copy)); model.save(copy); XCTAssertFalse(api.calls.contains(where: { $0.hasPrefix("save:") }))
        model.close(); XCTAssertNil(model.details(row)); model.save(row)
        do { _ = try await model.preparePlay(row); XCTFail("Closed view cannot play") } catch { }
        XCTAssertFalse(api.calls.contains(where: { $0.hasPrefix("details:") }))
    }
    func testExplicitPlayUsesActualDetailsResumeAndExistingPlaybackRequest() async throws {
        let api = PostPlayFixtureAPI(), model = try await ready(api); defer { model.close() }
        let row = try XCTUnwrap(model.suggestions.first)
        XCTAssertNotNil(model.details(row)); XCTAssertFalse(api.calls.contains(where: { $0.hasPrefix("details:") }))
        let request = try await model.preparePlay(row)
        XCTAssertEqual(request.title.titleID, row.title.id); XCTAssertEqual(request.start, .seconds(30)); XCTAssertTrue(request.postPlayStamp!.orderingKnown)
        XCTAssertEqual(api.calls.last, "details:" + row.title.id)
    }
    func testKnownContextDenialCannotFallBackOrWriteUsingAnotherProof() async throws {
        let api = PostPlayFixtureAPI(); api.contextError = APIError.http(HTTPFailure(status: 403, data: Data("{\"code\":\"profile_locked\"}".utf8)))
        let model = try await ready(api); defer { model.close() }
        XCTAssertFalse(model.current); model.load(); model.rate(.like)
        XCTAssertEqual(api.calls, ["context"]); XCTAssertTrue(model.suggestions.isEmpty)
    }
    func testUnacknowledgedCompletionDoesNotReadContextOrMintRatingUI() throws {
        let api = PostPlayFixtureAPI(), model = PostPlayModel(offer: try PostPlayFixture.offer(completed: false), api: api)
        model.load(); XCTAssertTrue(api.calls.isEmpty); XCTAssertNil(model.rating); XCTAssertNotNil(model.error); model.close()
    }
    func testReturnOrRepeatedReadDoesNotAskSameRatingQuestionAgain() async throws {
        let api = PostPlayFixtureAPI(), model = try await ready(api); defer { model.close() }
        XCTAssertTrue(model.question); model.load(); await until { !model.loading }
        XCTAssertFalse(model.question); XCTAssertEqual(model.rating, PersonalTitleRating.none); XCTAssertFalse(api.calls.contains(where: { $0.hasPrefix("rate:") }))
    }

    func testSeriesPlayWithoutDeliveredUpNextRequiresDetailsInsteadOfFirstEpisodeFallback() async throws {
        let api = PostPlayFixtureAPI(), series = try PostPlayFixture.title(2, series: true)
        api.suggestionsReply = PostPlaySuggestionsReply(items: [TrendingItem(rank: 1, title: series)], total: 1, source: "saved_choices", rating: .none, ratingScope: "movie")
        api.detailsReply = try PostPlayFixture.decode(["seriesDetails": ["title": ["id": series.id, "name": series.name, "mediaType": "series", "tmdbId": 2],
            "seasons": [["id": "s1", "name": "Season 1", "number": 1, "episodes": [["id": "actual-episode", "name": "Episode", "seasonNumber": 1, "episodeNumber": 1]]]]]])
        let model = try await ready(api); defer { model.close() }; let row = try XCTUnwrap(model.suggestions.first)
        do { _ = try await model.preparePlay(row); XCTFail("No delivered up-next target") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Choose an available episode")) }
        XCTAssertNotNil(model.details(row)); XCTAssertEqual(api.calls.last, "details:" + series.id)
    }
    func testLateRatingAcknowledgementCannotRefreshOrPublishForReplacementViewer() async throws {
        let api = PostPlayFixtureAPI(), model = try await ready(api); defer { model.close() }
        api.holdRating = true; model.rate(.dislike); await until { api.pendingRating != nil }
        api.context = PostPlayFixture.context("replacement"); api.pendingRating?.resume(returning: .dislike); api.pendingRating = nil
        await until { !model.saving }
        XCTAssertNotEqual(model.rating, .dislike); XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("suggestions:") }.count, 1)
    }

}
