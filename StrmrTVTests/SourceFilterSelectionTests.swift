import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class SourceFilterSelectionTests: XCTestCase {
    func until(_ predicate: () -> Bool) async { for _ in 0..<1000 { if !predicate() { await Task.yield() } } }
    func ready(_ api: SourceFilterFixtureAPI) async throws -> SourceFilterModel {
        let model = SourceFilterModel(title: try SourceFilterFixture.title(), episode: nil, api: api, now: { SourceFilterFixture.now })
        model.appear(); await until { !model.loading }; return model
    }
    func testEqualCopiedRowCannotAcquireActualPickerSelection() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        let row = try XCTUnwrap(model.rows.first)
        let copy = SourceFilterRow(result: row.result, verdict: row.verdict, evidence: row.evidence)
        XCTAssertFalse(model.canSelect(copy)); XCTAssertNil(model.beginManual(copy)); XCTAssertNotNil(model.take(row))
    }
    func testExactManualReceiptSurvivesOwnProbeButOrdinaryFilterRowsNeedReapply() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        let result = try XCTUnwrap(model.beginManual(try XCTUnwrap(model.rows.first)))
        var callbacks = 0
        let tracks = SourceTracksModel(result: result, cached: nil, api: api) { _ in callbacks += 1 }
        tracks.start(); await until { callbacks == 1 }
        XCTAssertEqual(api.probes, 1); XCTAssertTrue(model.needsApply)
        XCTAssertFalse(model.canSelect(try XCTUnwrap(model.rows.first)))
        let selected = try XCTUnwrap(model.takeManual(result)); XCTAssertNil(selected.filterSelection)
        XCTAssertTrue(NSDictionary(dictionary: selected.raw).isEqual(to: result.raw)); XCTAssertNil(model.takeManual(result)); tracks.cancel()
    }
    func testCancellingActualTrackModelEndsItsManualReceiptAndDropsLateProbe() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        api.holdProbe = true
        let result = try XCTUnwrap(model.beginManual(try XCTUnwrap(model.rows.first)))
        var callbacks = 0
        let tracks = SourceTracksModel(result: result, cached: nil, api: api) { _ in callbacks += 1 }
        tracks.start(); await until { api.pendingProbe != nil }; tracks.cancel()
        api.pendingProbe?.resume(returning: SourceFilterFixture.probe()); api.pendingProbe = nil
        await until { !result.filterSelection!.current }
        XCTAssertEqual(callbacks, 0); XCTAssertNil(tracks.probe); XCTAssertNil(model.takeManual(result))
    }
    func testNewManualRowInvalidatesOldDeferredProbeWithoutChangingRawResults() async throws {
        let api = try SourceFilterFixtureAPI(); api.initial = .supported(try SourceFilterFixture.page(indices: [0, 1], total: 2))
        let model = try await ready(api); defer { model.close() }; api.holdProbe = true
        let old = try XCTUnwrap(model.beginManual(model.rows[0])); var callbacks = 0
        let tracks = SourceTracksModel(result: old, cached: nil, api: api) { _ in callbacks += 1 }
        tracks.start(); await until { api.pendingProbe != nil }
        let replacement = try XCTUnwrap(model.beginManual(model.rows[1]))
        api.pendingProbe?.resume(returning: SourceFilterFixture.probe()); api.pendingProbe = nil
        await Task.yield(); await Task.yield()
        XCTAssertEqual(callbacks, 0); XCTAssertNil(model.takeManual(old)); XCTAssertNotNil(model.takeManual(replacement)); tracks.cancel()
    }
    func testOldContextProbeCannotPublishOrSelectAfterProfileSwitch() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }; api.holdProbe = true
        let result = try XCTUnwrap(model.beginManual(try XCTUnwrap(model.rows.first))); var callbacks = 0
        let tracks = SourceTracksModel(result: result, cached: nil, api: api) { _ in callbacks += 1 }
        tracks.start(); await until { api.pendingProbe != nil }; api.context = StoredMediaFixture.context("replacement")
        api.pendingProbe?.resume(returning: SourceFilterFixture.probe()); api.pendingProbe = nil
        await Task.yield(); await Task.yield()
        XCTAssertEqual(callbacks, 0); XCTAssertNil(model.takeManual(result)); XCTAssertEqual(api.probes, 1); tracks.cancel()
    }
    func testActualReturnedFileVersionIsRetainedAsCorrelationWithoutInventingFacts() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        let result = try XCTUnwrap(model.beginManual(try XCTUnwrap(model.rows.first)))
        let evidence = SourceFilterEvidence(candidateVersion: result.candidateVersion!, sourceVersion: "file_v1_" + String(repeating: "a", count: 64), probed: true)
        var probe = SourceFilterFixture.probe(); probe.evidence = evidence
        result.filterSelection?.probed(probe)
        XCTAssertEqual(model.latestEvidence[result.index], evidence); XCTAssertTrue(model.needsApply)
        XCTAssertNotNil(model.takeManual(result)); XCTAssertEqual(api.probes, 0)
    }
    func testKnownManualProbeDenialRetiresSelectionWithoutFallbackOrPage() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        api.probeError = SourceFilterFixture.error("profile_locked", status: 403)
        let result = try XCTUnwrap(model.beginManual(try XCTUnwrap(model.rows.first)))
        let tracks = SourceTracksModel(result: result, cached: nil, api: api) { _ in XCTFail("Denied probe cannot publish") }
        tracks.start(); await until { model.needsReload }
        XCTAssertTrue(model.rows.isEmpty); XCTAssertNil(model.takeManual(result)); XCTAssertTrue(api.reads.isEmpty)
        XCTAssertEqual(api.searches, 1); XCTAssertEqual(api.probes, 1); tracks.cancel()
    }
    func testDelayedTVAdmissionCannotRunAfterPickerCloseOrExplicitReload() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api)
        let result = try XCTUnwrap(model.beginManual(try XCTUnwrap(model.rows.first)))
        XCTAssertNotNil(model.takeManual(result)); let admitted = model.captureAdmission(); XCTAssertTrue(admitted())
        model.close(); XCTAssertFalse(admitted())
    }
    func testFilterApplyInvalidatesPendingManualReceiptAndOldView() async throws {
        let api = try SourceFilterFixtureAPI(), model = try await ready(api); defer { model.close() }
        let result = try XCTUnwrap(model.beginManual(try XCTUnwrap(model.rows.first)))
        model.draft.audioLanguage = "deu"; model.apply(); await until { !model.loading }
        XCTAssertNil(model.takeManual(result)); XCTAssertEqual(api.probes, 0); XCTAssertEqual(api.searches, 1)
    }
    func testFilteredOrIncompletePagesNeverExportAsCompleteSwitchSourceSet() throws {
        let incomplete = try SourceFilterFixture.page(indices: [0], total: 2, cursor: "next")
        XCTAssertFalse(SourceSearch.canExport(incomplete, loaded: 1))
        let filtered = try SourceFilterFixture.page(filters: SourceFilters(audioLanguage: "deu"))
        XCTAssertFalse(SourceSearch.canExport(filtered, loaded: 1))
        XCTAssertTrue(SourceSearch.canExport(try SourceFilterFixture.page(), loaded: 1))
    }
    func testCacheKeysKeepActualNumberingProviderAsWellAsOrdering() {
        let first = SourceSearch.Key(titleID: "tmdb:series:41", query: "Synthetic S02E03", ordering: "official", numberingID: "tvdb:series:1")
        let second = SourceSearch.Key(titleID: "tmdb:series:41", query: "Synthetic S02E03", ordering: "official", numberingID: "tvdb:series:2")
        XCTAssertNotEqual(first, second)
    }
    func testUnknownRowsAreLabelledUnknownRatherThanPositiveMatches() {
        XCTAssertEqual(SourceFilterLabels.verdict("unknown", basis: "probed"), "Unknown facts included by the selected policy")
        XCTAssertEqual(SourceFilterLabels.verdict("match", basis: "candidate"), "Matches release claims")
        XCTAssertEqual(SourceFilterLabels.verdict("match", basis: "probed"), "Matches existing file metadata")
    }
}
