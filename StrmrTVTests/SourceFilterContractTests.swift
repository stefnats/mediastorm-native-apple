import Foundation
import XCTest
@testable import StrmrTV

@MainActor
enum SourceFilterFixture {
    static func title(series: Bool = false) throws -> DetailsTarget {
        let value: Title = try StoredMediaWire.decode(Title.self, ["id": series ? "tmdb:series:41" : "tmdb:movie:12", "name": "Synthetic", "mediaType": series ? "series" : "movie", "year": 2026])
        return DetailsTarget(value)
    }
    static func episode() throws -> Episode {
        try StoredMediaWire.decode(Episode.self, ["id": "episode-original", "name": "Episode", "seasonNumber": 2, "episodeNumber": 3, "numbering": ["seriesId": "tvdb:series:74852", "ordering": "official"]])
    }
    static let now = Date(timeIntervalSince1970: 1_795_348_800)
    static func raw(_ index: Int) -> [String: Any] { ["title": "Synthetic release \(index)", "guid": "synthetic-\(index)", "serviceType": "usenet", "sizeBytes": 9_007_199_254_740_993, "attributes": ["raw_title": "Unchanged original", "custom": "retained"]] }
    static func candidate(_ index: Int) -> String { "candidate_v1_" + String(repeating: String(index % 10), count: 64) }
    static func envelope(indices: [Int] = [0], total: Int = 1, retained: Int? = nil, filters: SourceFilters = SourceFilters(), cursor: String? = nil, view: String = "original-view", snapshot: String = "original-snapshot", target: SourceFilterTarget? = nil) throws -> [String: Any] {
        let target = try target ?? SourceFilterTarget(title: title(), episode: nil)
        let targetJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target))
        var result: [String: Any] = ["sourceFiltersVersion": 1, "snapshotId": snapshot, "viewId": view, "expiresAt": "2026-11-22T12:05:00Z", "target": targetJSON,
            "filters": try filters.body(), "rows": indices.map { ["sourceIndex": $0, "candidateVersion": candidate($0), "result": raw($0), "verdict": filters.active ? "match" : "unfiltered"] },
            "total": total, "matchedTotal": filters.active ? total : 0, "unknownTotal": 0, "coverage": ["retainedCandidates": retained ?? total, "truncated": false]]
        if let cursor { result["nextCursor"] = cursor }; return result
    }
    static func page(indices: [Int] = [0], total: Int = 1, retained: Int? = nil, filters: SourceFilters = SourceFilters(), cursor: String? = nil, view: String = "original-view", snapshot: String = "original-snapshot") throws -> SourceFilterPage {
        try SourceFilterWire.page(envelope(indices: indices, total: total, retained: retained, filters: filters, cursor: cursor, view: view, snapshot: snapshot))
    }
    static func error(_ code: String, status: Int = 409) -> APIError { .http(HTTPFailure(status: status, data: Data("{\"code\":\"\(code)\",\"error\":\"Synthetic\"}".utf8))) }
    static func probe() -> SourceTrackProbe { SourceTrackProbe(playable: true, audio: [ProbedAudioTrack(index: 4, language: "deu", codec: "aac")], subtitles: [], tracksLoading: false, error: nil) }
}

@MainActor
final class SourceFilterContractTests: XCTestCase {
    func testVersionOneSearchUsesActualOriginalEpisodeIdentityAndNumbering() throws {
        let query = try APIClient.sourceFilterQuery(title: SourceFilterFixture.title(series: true), episode: SourceFilterFixture.episode(), context: StoredMediaFixture.context())
        XCTAssertEqual(query["sourceFiltersVersion"], "1"); XCTAssertEqual(query["episodeId"], "episode-original")
        XCTAssertEqual(query["episodeNumberingId"], "tvdb:series:74852"); XCTAssertEqual(query["episodeOrdering"], "official")
        XCTAssertEqual(query["seasonNumber"], "2"); XCTAssertEqual(query["episodeNumber"], "3"); XCTAssertEqual(query["userId"], "original")
    }
    func testActualLegacyArrayOnlyDisablesFiltersAndPreservesIndexes() throws {
        let data = try JSONSerialization.data(withJSONObject: [SourceFilterFixture.raw(0), 7, SourceFilterFixture.raw(2)] as [Any])
        guard case let .legacy(rows) = try SourceFilterWire.initial(data) else { return XCTFail("Expected actual legacy array") }
        XCTAssertEqual(rows.map(\.id), [0, 2]); XCTAssertNil(rows.first?.result.snapshotID)
        XCTAssertThrowsError(try SourceFilterWire.initial(Data("{\"items\":[]}".utf8)))
    }
    func testPageBodyUsesActualVersionFiltersCursorLimitWithoutSearchFields() throws {
        let filters = SourceFilters(audioLanguage: "deu", claimedResolutionAtLeast: "1080p")
        let body = try APIClient.sourceFilterPageBody(filters: filters, cursor: "opaque-cursor", limit: 100)
        XCTAssertEqual(body["version"] as? Int, 1); XCTAssertEqual(body["cursor"] as? String, "opaque-cursor")
        XCTAssertEqual((body["filters"] as? [String: Any])?["audioLanguage"] as? String, "deu"); XCTAssertNil(body["q"])
        XCTAssertThrowsError(try APIClient.sourceFilterPageBody(filters: filters, cursor: nil, limit: 101))
    }
    func testCandidateClaimsAndExistingFileMetadataCannotBeCombined() {
        XCTAssertThrowsError(try SourceFilters(audioCodec: "aac").validated())
        XCTAssertThrowsError(try SourceFilters(heightAtLeast: 1080).validated())
        XCTAssertThrowsError(try SourceFilters(basis: "probed", claimedResolutionAtLeast: "1080p").validated())
        XCTAssertThrowsError(try SourceFilters(basis: "probed", audioDescription: false).validated())
        XCTAssertThrowsError(try SourceFilters(audioLanguage: "de").validated())
    }
    func testBasisSwitchClearsOnlyFieldsIncompatibleWithNewBasis() throws {
        var value = SourceFilters(audioLanguage: "deu", claimedResolutionAtLeast: "1080p", videoCodec: "hevc")
        value.chooseBasis("probed"); XCTAssertNil(value.claimedResolutionAtLeast); XCTAssertEqual(value.audioLanguage, "deu")
        value.audioCodec = "aac"; value.heightAtLeast = 1080; value.audioDescription = true; value.chooseBasis("candidate")
        XCTAssertNil(value.audioCodec); XCTAssertNil(value.heightAtLeast); XCTAssertNil(value.audioDescription); XCTAssertEqual(value.videoCodec, "hevc")
        XCTAssertNoThrow(try value.validated())
    }
    func testStableIndexesAndCandidateVersionNeverBecomeDisplayedPagePositions() throws {
        let page = try SourceFilterFixture.page(indices: [51, 83], total: 2, retained: 100, filters: SourceFilters(audioLanguage: "deu"))
        XCTAssertEqual(page.rows.map(\.id), [51, 83]); XCTAssertEqual(page.rows[1].result.candidateVersion, SourceFilterFixture.candidate(83))
        XCTAssertEqual(page.rows[1].result.snapshotID, "original-snapshot")
    }
    func testResultRawAndExactInt64SurviveOuterCorrelation() throws {
        let result = try XCTUnwrap(SourceFilterFixture.page(indices: [6], total: 1, retained: 7, filters: SourceFilters(audioLanguage: "deu")).rows.first?.result)
        XCTAssertTrue(NSDictionary(dictionary: result.raw).isEqual(to: SourceFilterFixture.raw(6)))
        XCTAssertEqual(result.sizeBytes, 9_007_199_254_740_993); XCTAssertNil(result.raw["snapshotId"])
    }
    func testMalformedVersionIdentityCoverageCountsAndDuplicateRowsAreRejected() throws {
        let valid = try SourceFilterFixture.envelope()
        for (key, value) in [("sourceFiltersVersion", "1" as Any), ("snapshotId", ""), ("total", true), ("unknownTotal", 2), ("coverage", ["retainedCandidates": 513, "truncated": false])] {
            var raw = valid; raw[key] = value; XCTAssertThrowsError(try SourceFilterWire.page(raw))
        }
        var raw = valid; raw["rows"] = [["sourceIndex": 0, "candidateVersion": "wrong", "result": SourceFilterFixture.raw(0), "verdict": "unfiltered"]]
        XCTAssertThrowsError(try SourceFilterWire.page(raw))
        raw = try SourceFilterFixture.envelope(indices: [0, 0], total: 2); XCTAssertThrowsError(try SourceFilterWire.page(raw))
    }
    func testUnknownVerdictAndPolicyCountsCannotMasqueradeAsPositiveMatch() throws {
        let filters = SourceFilters(unknown: "exclude", audioLanguage: "deu")
        var raw = try SourceFilterFixture.envelope(filters: filters)
        raw["rows"] = [["sourceIndex": 0, "candidateVersion": SourceFilterFixture.candidate(0), "result": SourceFilterFixture.raw(0), "verdict": "unknown"]]
        XCTAssertThrowsError(try SourceFilterWire.page(raw))
        raw = try SourceFilterFixture.envelope(filters: filters); raw["matchedTotal"] = 0; raw["unknownTotal"] = 1
        XCTAssertThrowsError(try SourceFilterWire.page(raw))
    }
    func testActualProbeBodyUsesSnapshotIdSourceIndexAndOriginalProfile() throws {
        let result = try XCTUnwrap(SourceFilterFixture.page(indices: [73], total: 1, retained: 100, filters: SourceFilters(audioLanguage: "deu")).rows.first?.result)
        let body = APIClient.sourceFilterProbeBody(result, context: StoredMediaFixture.context())
        XCTAssertEqual(body["snapshotId"] as? String, "original-snapshot"); XCTAssertEqual(body["sourceIndex"] as? Int, 73)
        XCTAssertEqual(body["profileId"] as? String, "original"); XCTAssertEqual(body["probeForTracks"] as? Bool, true)
        XCTAssertNil(body["searchId"]); XCTAssertNil(body["expectedFileVersion"])
        XCTAssertTrue(NSDictionary(dictionary: body["result"] as! [String: Any]).isEqual(to: result.raw))
    }
    func testOptionalEvidenceIsDefensiveAndRequiresActualCandidateFileIdentity() throws {
        let candidate = SourceFilterFixture.candidate(0), file = "file_v1_" + String(repeating: "a", count: 64)
        XCTAssertEqual(SourceFilterEvidence.parse(["version": 1, "sourceVersion": file, "candidateVersion": candidate, "probed": [:]], candidate: candidate)?.sourceVersion, file)
        XCTAssertNil(SourceFilterEvidence.parse(["version": 1, "sourceVersion": file, "candidateVersion": candidate, "probed": [:]], candidate: SourceFilterFixture.candidate(1)))
        XCTAssertNil(SourceFilterEvidence.parse(["version": 1, "sourceVersion": "unknown", "candidateVersion": candidate]))
    }
    func testOriginalRequestUsesProxyAndCapturedProofForPageOnly() throws {
        let request = try APIClient.sourceFilterRequest(StoredMediaFixture.context(), method: "POST", path: "/api/users/original/source-searches/opaque/page", body: APIClient.sourceFilterPageBody(filters: SourceFilters(), cursor: nil))
        XCTAssertEqual(request.url?.path, "/proxy/api/users/original/source-searches/opaque/page")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Unlock"), "synthetic-proof")
        XCTAssertEqual(request.httpMethod, "POST")
    }
}
