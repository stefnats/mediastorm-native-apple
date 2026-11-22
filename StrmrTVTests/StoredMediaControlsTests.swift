import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class StoredMediaControlsTests: XCTestCase {
    func testOnlyActuallyStoredSourcesExposeTheSharedEntry() {
        for list in [BrowseList.watchlist, .custom(id: "saved", name: "Saved"), .permanentPrequeue, .hidden, .continueWatching, .popularOnServer, .similar(tmdbID: "1", kind: .movies, seed: "Saved", backdrop: nil), StoredMediaFixture.list] { XCTAssertTrue(list.storedEligible) }
        for list in [BrowseList.trending(.movies), .topTen(nil), .personalized, .remote(id: "external", name: "External", query: ["source": "mdblist", "url": "https://synthetic.invalid/list"])] { XCTAssertFalse(list.storedEligible) }
        XCTAssertTrue(StoredMediaFixture.list.isDirectSavedCatalogue)
        XCTAssertFalse(BrowseList.popularOnServer.isDirectSavedCatalogue)
    }
    func testLocalCustomListShelfIsDistinctFromExternalList() {
        XCTAssertTrue(BrowseList.remote(id: "saved", name: "Saved", query: ["source": "mdblist", "url": "mediastorm:custom-list:owned"]).storedEligible)
        XCTAssertFalse(BrowseList.remote(id: "external", name: "External", query: ["source": "tmdb-list", "listId": "1"]).storedEligible)
        XCTAssertTrue(BrowseList.remote(id: "saved", name: "Saved", query: ["source": "tmdb-public-list-cached", "listId": "1"]).storedEligible)
    }
    func testControlsUseSeparateStoredAndOriginalLanguagePolicies() throws {
        var options = BrowseOptions(); options.storedMedia.audioLanguage = "deu"
        XCTAssertFalse(options.originalLanguageActive); XCTAssertTrue(options.savedFiltersActive)
        XCTAssertThrowsError(try StoredMediaCapability(originalLanguage: true).require(options))
        options.storedMedia = StoredMediaFilters(); options.originalLanguages = ["deu"]
        XCTAssertNoThrow(try StoredMediaCapability(originalLanguage: true).require(options))
        XCTAssertThrowsError(try StoredMediaCapability(media: true, basis: StoredMediaFilters.basis).require(options))
    }
    func testSameSharedVocabularyIncludesAllMediaFieldsAndUnknownModes() throws {
        XCTAssertTrue(MediaFilterValues.videoCodecs.contains("hevc")); XCTAssertTrue(MediaFilterValues.audioCodecs.contains("eac3"))
        XCTAssertTrue(MediaFilterValues.ranges.contains("dolby_vision")); XCTAssertTrue(MediaFilterValues.heights.contains(2160))
        for unknown in ["include", "exclude", "only"] {
            XCTAssertEqual(try StoredMediaFilters(audioCodec: "aac", unknown: unknown).query()["mediaUnknown"], unknown)
        }
    }
    func testHiddenRowsRetainActualIdentityForExplicitUnhide() throws {
        let raw: [String: Any] = ["source": "hidden", "total": 1, "originalLanguageFilterSupported": true,
            "items": [["id": "tmdb:movie:4", "mediaType": "movie", "name": "Hidden"]]]
        let page = try StoredMediaWire.page(StoredMediaFixture.reply(raw), list: .hidden, options: BrowseOptions(), query: ["source": "hidden"], limit: 60, offset: 0)
        XCTAssertEqual(page.savedHidden?.first?.id, "tmdb:movie:4"); XCTAssertEqual(page.entries.first?.id, "tmdb:movie:4")
    }
    func testContinueWatchingKeepsDeliveredResumeAndCompleteOriginalPool() throws {
        let raw: [String: Any] = ["source": "continue-watching-cached", "total": 1, "originalLanguageFilterSupported": true,
            "pool": ["id": String(repeating: "a", count: 32), "observedAt": "2026-11-22T12:00:00Z", "expiresAt": "2026-11-22T12:05:00Z", "complete": true],
            "items": [["seriesId": "tmdb:movie:4", "seriesTitle": "Saved", "mediaType": "movie", "updatedAt": "2026-11-22T11:59:00Z", "resume": ["position": 120, "duration": 1200, "percent": 10, "eligible": true]]]]
        let page = try StoredMediaWire.page(StoredMediaFixture.reply(raw, date: "Sun, 22 Nov 2026 12:00:00 GMT"), list: .continueWatching, options: BrowseOptions(), query: ["source": "continue-watching-cached"], limit: 60, offset: 0)
        let item = try XCTUnwrap(page.savedWatching?.first)
        XCTAssertEqual(item.resume?.startPoint, .seconds(120)); XCTAssertEqual(HomeCard(item).progress, 0.1)
        XCTAssertNotNil(page.savedObservation)
    }
    func testOriginalLibraryLanguageDoesNotImplyStoredFileSupport() throws {
        let library = LibraryRef(id: "local", name: "Local", sourceType: "local")
        var options = BrowseOptions(); options.originalLanguages = ["deu"]
        let reply = try StoredMediaFixture.reply(["groups": [], "total": 0, "originalLanguageFilterSupported": true])
        let page = try StoredMediaWire.library(reply, library: library, options: options)
        XCTAssertTrue(page.savedCapability.originalLanguage); XCTAssertFalse(page.savedCapability.media)
        options.storedMedia.audioCodec = "aac"
        XCTAssertThrowsError(try StoredMediaWire.library(reply, library: library, options: options))
    }
}
