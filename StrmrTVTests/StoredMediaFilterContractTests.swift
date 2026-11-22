import Foundation
import XCTest
@testable import StrmrTV

@MainActor
enum StoredMediaFixture {
    static let list = BrowseList.remote(id: "loved-stored", name: "Loved titles", query: ["source": "loved-stored"])
    static func context(_ profile: String = "original") -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://synthetic.invalid/proxy")!, profileID: profile, clientID: "synthetic-client", sessionToken: "synthetic-session", unlock: "synthetic-proof")
    }
    static func title(_ id: Int = 1) -> [String: Any] { ["id": "tmdb:movie:\(id)", "mediaType": "movie", "name": "Saved \(id)"] }
    static func reply(_ raw: [String: Any], date: String? = nil) throws -> StoredMediaReply {
        StoredMediaReply(data: try JSONSerialization.data(withJSONObject: raw), status: 200, date: date, started: .now, received: .now)
    }
    static func page(total: Int = 1, ids: [Int] = [1], options: BrowseOptions = BrowseOptions(), offset: Int = 0, support: Bool = true, basis: String? = nil) throws -> BrowsePage {
        var raw: [String: Any] = ["source": "loved-stored", "total": total, "items": ids.enumerated().map { ["rank": offset + $0.offset + 1, "title": title($0.element)] }, "originalLanguageFilterSupported": true, "storedMediaFilterSupported": support]
        if let basis { raw["storedMediaFilterBasis"] = basis }
        return try StoredMediaWire.page(reply(raw), list: list, options: options, query: ["source": "loved-stored"], limit: 60, offset: offset)
    }
}

@MainActor
final class StoredMediaFilterContractTests: XCTestCase {
    func testCanonicalRegisteredLanguagesPreserveDistinctNorwegianCodes() throws {
        XCTAssertEqual(MediaFilterValues.language("DE"), "deu"); XCTAssertEqual(MediaFilterValues.language("ger"), "deu")
        XCTAssertEqual(MediaFilterValues.language("nb"), "nob"); XCTAssertEqual(MediaFilterValues.language("no"), "nor")
        for code in ["und", "mul", "zxx", "xx", "not-a-language"] { XCTAssertNil(MediaFilterValues.language(code)) }
    }
    func testExactEightMediaKeysAndUnknownOnlyNeedAnActualCriterion() throws {
        var f = StoredMediaFilters(audioLanguage: "en", subtitleLanguage: "fr", audioCodec: "eac3", videoCodec: "hevc", hdr: "hdr10", minHeight: 1080, subtitles: "present", unknown: "only")
        XCTAssertEqual(try f.query(), ["audioLanguage": "eng", "subtitleLanguage": "fra", "audioCodec": "eac3", "videoCodec": "hevc", "hdr": "hdr10", "minHeight": "1080", "subtitles": "present", "mediaUnknown": "only"])
        f = StoredMediaFilters(unknown: "only"); XCTAssertTrue(try f.query().isEmpty)
    }
    func testInvalidCriteriaAreRejectedInsteadOfSilentlyCleared() {
        for f in [StoredMediaFilters(audioLanguage: "und"), StoredMediaFilters(audioCodec: "AAC!"), StoredMediaFilters(hdr: "HDR"), StoredMediaFilters(minHeight: 100), StoredMediaFilters(subtitles: "maybe"), StoredMediaFilters(audioCodec: "aac", unknown: "maybe")] { XCTAssertThrowsError(try f.query()) }
    }
    func testOriginalLanguageSetUsesActualQueryAndDoesNotBecomeAudioLanguage() throws {
        var options = BrowseOptions(); options.originalLanguages = ["de", "ger", "en"]; options.includeUnknownOriginalLanguage = true
        XCTAssertEqual(try options.savedQuery(), ["originalLanguages": "deu,eng", "includeUnknownOriginalLanguage": "true"])
    }
    func testActiveReplyRequiresDedicatedSupportAndExactBasis() throws {
        var options = BrowseOptions(); options.storedMedia.audioCodec = "aac"
        for (supported, basis) in [(false, String?.none), (true, nil), (true, "candidate_claims")] {
            XCTAssertThrowsError(try StoredMediaFixture.page(options: options, support: supported, basis: basis))
        }
        XCTAssertEqual(try StoredMediaFixture.page(options: options, basis: StoredMediaFilters.basis).total, 1)
    }
    func testOnlyActualBooleanMarkersAdvertiseSupport() {
        for raw in [1 as Any, "true", NSNull()] { XCTAssertFalse(StoredMediaWire.capability(["storedMediaFilterSupported": raw]).media) }
        XCTAssertTrue(StoredMediaWire.capability(["storedMediaFilterSupported": true]).media)
    }
    func testLovedStoredUsesRankedTitleActualRouteAndFilteredTotal() throws {
        let query = try APIClient.savedCatalogueQuery(StoredMediaFixture.list, options: BrowseOptions(), limit: 60, offset: 0)
        XCTAssertEqual(query["source"], "loved-stored")
        let page = try StoredMediaFixture.page(); XCTAssertEqual(page.entries.first?.id, "tmdb:movie:1"); XCTAssertEqual(page.total, 1)
    }
    func testSourceSpecificSortsNeverForwardUnsupportedCachedSort() {
        let list = BrowseList.similar(tmdbID: "12", kind: .movies, seed: "Saved", backdrop: nil)
        var options = BrowseOptions(); options.sort = .year
        XCTAssertThrowsError(try APIClient.savedCatalogueQuery(list, options: options, limit: 60, offset: 0))
    }
    func testLibraryMarkersAndOriginalLanguageRemainSeparateOnPlexAndJellyfin() throws {
        for source in ["local", "plex", "jellyfin"] {
            let library = LibraryRef(id: "stored", name: source, sourceType: source)
            var options = BrowseOptions(); options.storedMedia.audioCodec = "aac"
            let query = try APIClient.savedLibraryQuery(library, options: options, limit: 60, offset: 60, context: StoredMediaFixture.context())
            XCTAssertEqual(query["audioCodec"], "aac"); XCTAssertEqual(query["userId"], "original"); XCTAssertEqual(query["include"], "cards")
            let reply = try StoredMediaFixture.reply(["groups": [], "total": 0, "storedMediaFilterSupported": true, "storedMediaFilterBasis": StoredMediaFilters.basis])
            XCTAssertEqual(try StoredMediaWire.library(reply, library: library, options: options).total, 0)
            let old = try StoredMediaFixture.reply(["groups": [], "total": 0, "originalLanguageFilterSupported": true])
            XCTAssertThrowsError(try StoredMediaWire.library(old, library: library, options: options))
            options.originalLanguages = ["deu"]
            if source != "local" { XCTAssertThrowsError(try APIClient.savedLibraryQuery(library, options: options, limit: 60, offset: 0, context: StoredMediaFixture.context())) }
        }
    }
    func testRequestRetainsOriginalProxyViewerAndProof() throws {
        let request = try APIClient.storedMediaRequest(StoredMediaFixture.context(), path: "/api/users/original/display-list", query: ["source": "loved-stored", "profileId": "replacement"])
        XCTAssertEqual(request.url?.path, "/proxy/api/users/original/display-list")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "profileId" })?.value, "original")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Unlock"), "synthetic-proof")
    }
    func testCachedObservationRequiresActualDateAndCannotInventNewExpiry() throws {
        let list = BrowseList.similar(tmdbID: "12", kind: .movies, seed: "Saved", backdrop: nil)
        let raw: [String: Any] = ["source": "similar-cached", "items": [], "total": 0, "originalLanguageFilterSupported": true,
            "similar": ["tmdbId": 12, "mediaType": "movie", "metadataLanguage": "en", "observedAt": "2026-11-22T12:00:00Z", "expiresAt": "2026-11-22T12:01:00Z", "scope": "returned-results"]]
        let query = try APIClient.savedCatalogueQuery(list, options: BrowseOptions(), limit: 60, offset: 0)
        XCTAssertThrowsError(try StoredMediaWire.page(StoredMediaFixture.reply(raw), list: list, options: BrowseOptions(), query: query, limit: 60, offset: 0))
        let page = try StoredMediaWire.page(StoredMediaFixture.reply(raw, date: "Sun, 22 Nov 2026 12:00:00 GMT"), list: list, options: BrowseOptions(), query: query, limit: 60, offset: 0)
        XCTAssertNotNil(page.savedObservation)
        XCTAssertThrowsError(try StoredMediaWire.page(StoredMediaFixture.reply(raw, date: "Sun, 22 Nov 2026 12:02:00 GMT"), list: list, options: BrowseOptions(), query: query, limit: 60, offset: 0))
    }
    func testSourceAndPageCountCannotBeSubstitutedWithUnfilteredRows() throws {
        let raw: [String: Any] = ["source": "popular-on-server", "items": [], "total": 12, "originalLanguageFilterSupported": true]
        XCTAssertThrowsError(try StoredMediaWire.page(StoredMediaFixture.reply(raw), list: StoredMediaFixture.list, options: BrowseOptions(), query: ["source": "loved-stored"], limit: 60, offset: 0))
        XCTAssertThrowsError(try StoredMediaFixture.page(total: 61, ids: [1]))
    }
}
