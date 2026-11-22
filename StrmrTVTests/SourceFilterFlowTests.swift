import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class SourceFilterFixtureAPI: SourceFilterAPI {
    struct Read { let snapshot: String; let filters: SourceFilters; let cursor: String?; let context: SourceActionContext }
    var context = StoredMediaFixture.context()
    var searches = 0
    var reads: [Read] = []
    var probes = 0
    var healthReads = 0
    var initial: SourceFilterReply
    var pages: [SourceFilterPage] = []
    var searchError: Error?
    var pageError: Error?
    var probeError: Error?
    var holdPages = false
    var holdSearch = false
    var holdProbe = false
    var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    var pendingSearch: CheckedContinuation<Void, Error>?
    var pendingProbe: CheckedContinuation<SourceTrackProbe, Error>?
    private var completedPages: [Int: SourceFilterPage] = [:]
    private var completedSearches: [Int: SourceFilterReply] = [:]
    private var pendingSearchIndex: Int?
    init() throws { initial = .supported(try SourceFilterFixture.page()) }
    func sourceContext() -> SourceActionContext { context }
    func isCurrent(_ context: SourceActionContext) -> Bool { self.context == context }
    func sourceFilterSearch(title: DetailsTarget, episode: Episode?, context: SourceActionContext) async throws -> SourceFilterReply {
        searches += 1; if let searchError { throw searchError }
        if holdSearch {
            let index = searches
            pendingSearchIndex = index
            try await withCheckedThrowingContinuation { (gate: CheckedContinuation<Void, Error>) in pendingSearch = gate }
            guard let reply = completedSearches.removeValue(forKey: index) else { throw SourceFilterFailure.invalid }
            return reply
        }
        return initial
    }
    func sourceFilterPage(snapshot: String, filters: SourceFilters, cursor: String?, context: SourceActionContext) async throws -> SourceFilterPage {
        let index = reads.count; reads.append(Read(snapshot: snapshot, filters: filters, cursor: cursor, context: context))
        if let pageError { throw pageError }
        if holdPages {
            try await withCheckedThrowingContinuation { (gate: CheckedContinuation<Void, Error>) in pending[index] = gate }
            guard let page = completedPages.removeValue(forKey: index) else { throw SourceFilterFailure.invalid }
            return page
        }
        return pages.isEmpty ? try SourceFilterFixture.page(filters: filters, view: "applied-view") : pages.removeFirst()
    }
    func sourceFilterHealth(token: String, context: SourceActionContext) async throws -> SourceHealthSnapshot {
        healthReads += 1; return SourceHealthSnapshot(complete: true, results: [])
    }
    func probeTracks(_ result: SourceResult, context: SourceActionContext) async throws -> SourceTrackProbe {
        probes += 1; if let probeError { throw probeError }
        if holdProbe { return try await withCheckedThrowingContinuation { pendingProbe = $0 } }; return SourceFilterFixture.probe()
    }
    // Only the Void signal crosses the continuation boundary. Reference-bearing
    // replies stay on this actor until the original held operation consumes them.
    func finish(_ index: Int, _ page: SourceFilterPage) {
        guard let gate = pending.removeValue(forKey: index) else { return }
        completedPages[index] = page
        gate.resume()
    }
    func finishSearch(_ reply: SourceFilterReply) {
        guard let index = pendingSearchIndex, let gate = pendingSearch else { return }
        pendingSearch = nil; pendingSearchIndex = nil
        completedSearches[index] = reply
        gate.resume()
    }
}

@MainActor
final class SourceFilterFlowTests: XCTestCase {
    @nonobjc func until(_ predicate: () -> Bool) async { for _ in 0..<1000 where !predicate() { await Task.yield() } }
    func ready(_ api: SourceFilterFixtureAPI) async throws -> SourceFilterModel {
        let model = SourceFilterModel(title: try SourceFilterFixture.title(), episode: nil, api: api, now: { SourceFilterFixture.now })
        model.appear(); await until { !model.loading }; return model
    }
    func testOneInitialSearchThenMoreReadsOnlyRetainedSnapshotWithStableIndexes() async throws {
        let api = try SourceFilterFixtureAPI()
        api.initial = .supported(try SourceFilterFixture.page(indices: Array(0..<50), total: 83, cursor: "next"))
        api.pages = [try SourceFilterFixture.page(indices: Array(50..<83), total: 83)]
        let model = try await ready(api); defer { model.close() }
        model.more(); await until { !model.loading }
        XCTAssertEqual(model.rows.count, 83); XCTAssertEqual(model.rows.last?.id, 82)
        XCTAssertEqual(api.searches, 1); XCTAssertEqual(api.probes, 0); XCTAssertEqual(api.reads.first?.cursor, "next")
        XCTAssertEqual(api.reads.first?.snapshot, "original-snapshot"); XCTAssertFalse(model.hasMore)
    }
    func testApplyChangesOnlySnapshotPageAndUsesOriginalContext() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        model.draft.audioLanguage = "deu"; model.apply(); await until { !model.loading }
        XCTAssertEqual(api.searches, 1); XCTAssertEqual(api.probes, 0); XCTAssertEqual(api.reads.count, 1)
        XCTAssertNil(api.reads[0].cursor); XCTAssertEqual(api.reads[0].context, api.context)
        XCTAssertEqual(model.page?.filters.audioLanguage, "deu")
    }
    func testLateMaskedOldFilterPageCannotReplaceNewAppliedView() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        api.holdPages = true
        model.draft.audioLanguage = "deu"; model.apply(); await until { api.pending[0] != nil }
        model.draft.audioLanguage = "fra"; model.apply(); await until { api.pending[1] != nil }
        api.finish(0, try SourceFilterFixture.page(filters: SourceFilters(audioLanguage: "deu"), view: "old"))
        api.finish(1, try SourceFilterFixture.page(filters: SourceFilters(audioLanguage: "fra"), view: "new"))
        await until { !model.loading }
        XCTAssertEqual(model.page?.viewId, "new"); XCTAssertEqual(model.page?.filters.audioLanguage, "fra"); XCTAssertEqual(api.searches, 1)
    }
    func testViewerChangeRetiresPendingInitialReplyWithoutReplacementRead() async throws {
        let api = try SourceFilterFixtureAPI(); api.holdSearch = true
        let model = SourceFilterModel(title: try SourceFilterFixture.title(), episode: nil, api: api, now: { SourceFilterFixture.now }); defer { model.close() }
        model.appear(); await until { api.pendingSearch != nil }
        api.context = StoredMediaFixture.context("replacement")
        api.finishSearch(.supported(try SourceFilterFixture.page()))
        await until { !model.loading }; model.reload()
        XCTAssertTrue(model.rows.isEmpty); XCTAssertEqual(api.searches, 1); XCTAssertFalse(model.current)
    }
    func testCloseSuppressesMaskedPendingSourcePageAndFutureOperations() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api)
        api.holdPages = true; model.draft.videoCodec = "hevc"; model.apply(); await until { api.pending[0] != nil }; model.close()
        api.finish(0, try SourceFilterFixture.page(filters: SourceFilters(videoCodec: "hevc")))
        await until { api.pending.isEmpty }; model.more(); model.apply(); model.reload()
        XCTAssertTrue(model.rows.isEmpty); XCTAssertEqual(api.searches, 1); XCTAssertEqual(api.reads.count, 1)
    }
    func testChangedViewRequiresExplicitReapplyWithoutAutomaticSearch() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        api.pageError = SourceFilterFixture.error("source_view_changed")
        model.draft.audioLanguage = "deu"; model.apply(); await until { !model.loading }
        XCTAssertTrue(model.needsApply); XCTAssertFalse(model.needsReload); XCTAssertEqual(api.searches, 1)
        api.pageError = nil; model.apply(); await until { !model.loading }
        XCTAssertFalse(model.needsApply); XCTAssertEqual(api.searches, 1); XCTAssertEqual(api.reads.count, 2)
    }
    func testSnapshotContextChangeRequiresExplicitReloadAndKeepsDraft() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        api.pageError = SourceFilterFixture.error("source_snapshot_context_changed")
        model.draft.audioLanguage = "deu"; model.apply(); await until { !model.loading }
        XCTAssertTrue(model.needsReload); model.apply(); XCTAssertEqual(api.reads.count, 1); XCTAssertEqual(api.searches, 1)
        api.pageError = nil; model.reload(); await until { !model.loading }
        XCTAssertEqual(api.searches, 2); XCTAssertEqual(model.page?.filters.audioLanguage, "deu")
    }
    func testWrongTargetOrSnapshotCannotPublishAReply() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        model.draft.audioLanguage = "deu"
        api.pages = [try SourceFilterFixture.page(filters: model.draft, snapshot: "replacement-snapshot")]
        model.apply(); await until { !model.loading }
        XCTAssertTrue(model.rows.isEmpty); XCTAssertNotNil(model.error); XCTAssertEqual(api.searches, 1)
    }
    func testRepeatedCursorOrChangedTotalCannotCreateDuplicatePages() async throws {
        let api = try SourceFilterFixtureAPI()
        api.initial = .supported(try SourceFilterFixture.page(indices: [0], total: 3, cursor: "same"))
        api.pages = [try SourceFilterFixture.page(indices: [1], total: 3, cursor: "same")]
        let model = try await ready(api); defer { model.close() }
        model.more(); await until { !model.loading }
        XCTAssertTrue(model.needsApply); XCTAssertTrue(model.rows.isEmpty); XCTAssertEqual(api.reads.count, 1)
    }
    func testOnlyActualLegacyArrayKeepsOrdinaryUnfilteredSelection() async throws {
        let api = try SourceFilterFixtureAPI()
        api.initial = try SourceFilterWire.initial(JSONSerialization.data(withJSONObject: [SourceFilterFixture.raw(7)]))
        let model = try await ready(api); defer { model.close() }
        XCTAssertFalse(model.supported); XCTAssertNotNil(model.take(try XCTUnwrap(model.rows.first)))
        model.apply(); XCTAssertTrue(api.reads.isEmpty); XCTAssertEqual(api.searches, 1)
    }
    func testExpiredOriginalViewCannotPageOrSelectAndDoesNotSearchAutomatically() async throws {
        let api = try SourceFilterFixtureAPI(); var now = SourceFilterFixture.now
        let model = SourceFilterModel(title: try SourceFilterFixture.title(), episode: nil, api: api, now: { now }); defer { model.close() }
        model.appear(); await until { !model.loading }; let row = try XCTUnwrap(model.rows.first)
        now = now.addingTimeInterval(901); XCTAssertFalse(model.canSelect(row)); model.more()
        XCTAssertTrue(api.reads.isEmpty); XCTAssertEqual(api.searches, 1)
    }
    func testKnownDenialDoesNotBecomeLegacyOrStartAnotherOperation() async throws {
        let api = try SourceFilterFixtureAPI(); api.searchError = SourceFilterFixture.error("profile_locked", status: 403)
        let model = try await ready(api); defer { model.close() }
        XCTAssertTrue(model.needsReload); XCTAssertTrue(model.rows.isEmpty); model.more(); model.apply(); model.reload()
        XCTAssertEqual(api.searches, 1); XCTAssertTrue(api.reads.isEmpty); XCTAssertEqual(api.probes, 0)
    }
    func testOldReloadCompletionCannotClearNewApplyLoadingOrTaskOwnership() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        model.draft.audioLanguage = "deu"; api.pageError = SourceFilterFixture.error("source_snapshot_context_changed")
        model.apply(); await until { !model.loading }; XCTAssertTrue(model.needsReload)
        api.pageError = nil; api.holdPages = true; model.reload(); await until { api.pending[1] != nil }
        model.draft.audioLanguage = "fra"; model.apply(); await until { api.pending[2] != nil }
        api.finish(1, try SourceFilterFixture.page(filters: SourceFilters(audioLanguage: "deu"), view: "old-reload"))
        await Task.yield(); await Task.yield(); XCTAssertTrue(model.loading)
        api.finish(2, try SourceFilterFixture.page(filters: SourceFilters(audioLanguage: "fra"), view: "new-apply"))
        await until { !model.loading }; XCTAssertEqual(model.page?.viewId, "new-apply"); XCTAssertEqual(api.searches, 2)
    }

    func testOrdinaryProviderSearchFailurePreservesExistingLibraryChoice() async throws {
        let api = try SourceFilterFixtureAPI(); api.searchError = SourceFilterFixture.error("reader_unavailable", status: 503)
        let model = try await ready(api); defer { model.close() }
        XCTAssertTrue(model.permitsLibrary); XCTAssertTrue(model.needsReload); XCTAssertFalse(model.denied)
        XCTAssertTrue(model.rows.isEmpty); XCTAssertEqual(api.searches, 1)
    }

}
