import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class StoredMediaFixtureAPI: StoredMediaAPI {
    struct Read { let options: BrowseOptions; let offset: Int; let context: SourceActionContext }
    var context = StoredMediaFixture.context()
    var reads: [Read] = []
    var pages: [BrowsePage] = []
    var hold = false
    var pending: [Int: CheckedContinuation<BrowsePage, Error>] = [:]
    var writes = 0
    var readError: Error?
    func sourceContext() -> SourceActionContext { context }
    func isCurrent(_ context: SourceActionContext) -> Bool { self.context == context }
    func savedMediaPage(_ list: BrowseList, options: BrowseOptions, limit: Int, offset: Int, context: SourceActionContext) async throws -> BrowsePage {
        let index = reads.count; reads.append(Read(options: options, offset: offset, context: context))
        if let readError { throw readError }
        if hold { return try await withCheckedThrowingContinuation { pending[index] = $0 } }
        return pages.isEmpty ? try StoredMediaFixture.page() : pages.removeFirst()
    }
    func savedMediaUnhide(_ item: HiddenItem, context: SourceActionContext) async throws { writes += 1 }
    func finish(_ index: Int, _ page: BrowsePage) { pending.removeValue(forKey: index)?.resume(returning: page) }
}

@MainActor
final class StoredMediaBrowseFlowTests: XCTestCase {
    @nonobjc func until(_ predicate: () -> Bool) async { for _ in 0..<1000 where !predicate() { await Task.yield() } }
    func ready(_ api: StoredMediaFixtureAPI) async -> StoredMediaBrowseModel {
        let model = StoredMediaBrowseModel(list: StoredMediaFixture.list, api: api)
        model.appear(); await until { !model.loading }; return model
    }
    func testPagingUsesCompleteServerTotalAndOriginalOffsetBeyondFirstPage() async throws {
        let api = StoredMediaFixtureAPI()
        api.pages = [try StoredMediaFixture.page(total: 61, ids: Array(1...60)), try StoredMediaFixture.page(total: 61, ids: [61], offset: 60)]
        let model = await ready(api)
        XCTAssertEqual(model.total, 61); XCTAssertEqual(model.rows.count, 60)
        model.loadMore(); await until { !model.loading }
        XCTAssertEqual(api.reads.map(\.offset), [0, 60]); XCTAssertEqual(model.rows.count, 61); XCTAssertFalse(model.hasMore)
        XCTAssertTrue(api.reads.allSatisfy { $0.context == api.context })
    }
    func testApplyResetsToZeroAndDropsLateMaskedOldFilterPage() async throws {
        let api = StoredMediaFixtureAPI(); api.hold = true
        let model = StoredMediaBrowseModel(list: StoredMediaFixture.list, api: api)
        model.appear(); await until { api.pending[0] != nil }
        model.draft.storedMedia.audioCodec = "aac"; model.apply(); await until { api.pending[1] != nil }
        api.finish(0, try StoredMediaFixture.page(ids: [1]))
        api.finish(1, try StoredMediaFixture.page(ids: [2], options: model.applied, basis: StoredMediaFilters.basis))
        await until { !model.loading }
        XCTAssertEqual(model.rows.map { $0.entry.id }, ["tmdb:movie:2"])
        XCTAssertEqual(api.reads.map(\.offset), [0, 0]); XCTAssertEqual(api.reads[1].options.storedMedia.audioCodec, "aac")
    }
    func testOriginalViewerSwitchCannotPublishOldReadOrReadAsReplacement() async throws {
        let api = StoredMediaFixtureAPI(); api.hold = true
        let model = StoredMediaBrowseModel(list: StoredMediaFixture.list, api: api)
        model.appear(); await until { api.pending[0] != nil }
        api.context = StoredMediaFixture.context("replacement"); api.finish(0, try StoredMediaFixture.page())
        await until { !model.loading }; model.refresh()
        XCTAssertTrue(model.rows.isEmpty); XCTAssertTrue(model.retired); XCTAssertEqual(api.reads.count, 1)
    }
    func testCloseCancelsPublicationAndReopenKeepsOriginalContext() async throws {
        let api = StoredMediaFixtureAPI(); api.hold = true
        let model = StoredMediaBrowseModel(list: StoredMediaFixture.list, api: api)
        model.appear(); await until { api.pending[0] != nil }; model.close()
        api.finish(0, try StoredMediaFixture.page()); await until { api.pending.isEmpty }
        XCTAssertTrue(model.rows.isEmpty)
        model.reopen(); await until { api.pending[1] != nil }
        api.finish(1, try StoredMediaFixture.page(ids: [2])); await until { !model.loading }
        XCTAssertEqual(model.rows.first?.entry.id, "tmdb:movie:2"); XCTAssertEqual(api.reads[1].context, api.reads[0].context)
    }
    func testUnknownCachedPoolErrorNeverFallsBackToDiscovery() async {
        let api = StoredMediaFixtureAPI(); api.readError = StoredMediaFailure.expired
        let model = await ready(api)
        XCTAssertEqual(api.reads.count, 1); XCTAssertTrue(model.rows.isEmpty); XCTAssertNotNil(model.error)
        model.refresh(); await until { !model.loading }; XCTAssertEqual(api.reads.count, 2)
    }
    func testUnsupportedActiveReplyDoesNotShowUnfilteredRowsOrClearSelection() async throws {
        let api = StoredMediaFixtureAPI(), model = StoredMediaBrowseModel(list: StoredMediaFixture.list, api: api)
        model.draft.storedMedia.hdr = "hdr10"; model.apply(); await until { !model.loading }
        XCTAssertTrue(model.rows.isEmpty); XCTAssertEqual(model.applied.storedMedia.hdr, "hdr10"); XCTAssertNotNil(model.error)
    }
    func testChangedObservationDuringPagingDropsOldAndNewRows() async throws {
        let api = StoredMediaFixtureAPI()
        var first = try StoredMediaFixture.page(total: 61, ids: Array(1...60))
        first.savedObservation = StoredMediaObservation(identity: "original", deadline: ContinuousClock.now.advanced(by: .seconds(60)))
        var next = try StoredMediaFixture.page(total: 61, ids: [61], offset: 60)
        next.savedObservation = StoredMediaObservation(identity: "replacement", deadline: ContinuousClock.now.advanced(by: .seconds(60)))
        api.pages = [first, next]; let model = await ready(api)
        model.loadMore(); await until { !model.loading }
        XCTAssertTrue(model.rows.isEmpty); XCTAssertNotNil(model.error); model.close()
    }
    func testExpiredObservationPreventsAnotherReadAndNeedsExplicitRefresh() async throws {
        let api = StoredMediaFixtureAPI()
        var page = try StoredMediaFixture.page()
        page.savedObservation = StoredMediaObservation(identity: "expired", deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
        api.pages = [page]; let model = await ready(api)
        model.loadMore(); XCTAssertTrue(model.rows.isEmpty); XCTAssertTrue(model.retired); XCTAssertEqual(api.reads.count, 1)
    }
    func testRankedDuplicateAdapterRowsKeepTheirServerCountAndUniqueGridIdentity() async throws {
        let api = StoredMediaFixtureAPI(); api.pages = [try StoredMediaFixture.page(total: 2, ids: [1, 1])]
        let model = await ready(api)
        XCTAssertEqual(model.total, 2); XCTAssertEqual(model.rows.count, 2); XCTAssertEqual(Set(model.rows.map(\.id)).count, 2)
    }
    func testClearSavedCriteriaPreservesOrdinarySortWatchGenreAndKind() async {
        let api = StoredMediaFixtureAPI(), model = StoredMediaBrowseModel(list: .watchlist, api: api)
        model.draft.sort = .name; model.draft.watch = .unwatched; model.draft.kind = .movies; model.draft.genres = ["Drama"]
        model.draft.originalLanguages = ["deu"]; model.draft.storedMedia.audioCodec = "aac"
        model.clearSavedFilters()
        XCTAssertFalse(model.draft.savedFiltersActive); XCTAssertEqual(model.draft.sort, .name); XCTAssertEqual(model.draft.watch, .unwatched)
        XCTAssertEqual(model.draft.genres, ["Drama"]); XCTAssertEqual(model.draft.kind, .movies); XCTAssertTrue(api.reads.isEmpty)
    }
    func testFilterChangesDoNotCombineLocalFileOrTrackFacts() async throws {
        let api = StoredMediaFixtureAPI(), model = StoredMediaBrowseModel(list: StoredMediaFixture.list, api: api)
        model.draft.storedMedia.audioLanguage = "deu"; model.draft.storedMedia.audioCodec = "aac"; model.draft.storedMedia.videoCodec = "hevc"
        api.pages = [try StoredMediaFixture.page(total: 0, ids: [], options: model.draft, basis: StoredMediaFilters.basis)]
        model.apply(); await until { !model.loading }
        XCTAssertEqual(api.reads.count, 1); XCTAssertTrue(model.rows.isEmpty); XCTAssertEqual(model.total, 0)
        XCTAssertEqual(api.reads[0].options.storedMedia.audioLanguage, "deu"); XCTAssertEqual(api.writes, 0)
    }
}
