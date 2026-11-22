import XCTest
import UIKit
@testable import StrmrTV

@MainActor
final class CombinedLibraryFileTests: XCTestCase {
    private func version() throws -> LibraryVersion {
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data(#"{"id":"physical","fileName":"Show.S01E01E02.mkv","sourceType":"local","episodes":[{"seasonNumber":1,"episodeNumber":1},{"seasonNumber":1,"episodeNumber":2}]}"#.utf8))
        return LibraryVersion(item: item, libraryName: "Shows")
    }

    private func playback(_ fields: String = "") throws -> LibraryPlaybackInfo {
        try JSONDecoder().decode(LibraryPlaybackInfo.self, from: Data("""
        {"itemId":"physical","streamPath":"localmedia:physical/Show.S01E01E02.mkv","progressScope":"file",
         "displayName":"Show S01E01 + S01E02","combinedEpisodes":[{"seasonNumber":1,"episodeNumber":1},{"seasonNumber":1,"episodeNumber":2}]\(fields)}
        """.utf8))
    }

    private func original() -> PlaybackRequest {
        let title = DetailsTarget(titleID: "tvdb:series:505", name: "Show", isMovie: false, year: 2024,
            tmdbID: "303", imdbID: "tt1234567", tvdbID: "505", posterURL: nil,
            textPosterURL: nil, backdropURL: nil, logoURL: nil, overview: nil)
        let episode = PlaybackRequest.EpisodeInfo(season: 1, episode: 2, absolute: nil,
                                                 name: "Second", itemID: "tvdb:series:505:s01e02")
        return PlaybackRequest(title: title, episode: episode, start: .seconds(300), following: [episode])
    }

    func testConfirmedFileClearsEpisodeResumeFollowingAndCatalogue() throws {
        let request = try CombinedLibraryFilePlayback.request(original(), version: version(), playback: playback())
        XCTAssertTrue(request.title.isMovie)
        XCTAssertFalse(request.title.hasCatalogIDs)
        XCTAssertTrue(request.isUnmatchedLibraryFile)
        XCTAssertNil(request.episode)
        XCTAssertNil(request.start)
        XCTAssertTrue(request.following.isEmpty)
        XCTAssertNil(request.nextEpisode)
        XCTAssertEqual(request.libraryVersion?.id, "physical")
        XCTAssertNil(request.title.tmdbID)
        XCTAssertNil(request.title.tvdbID)
        XCTAssertNil(request.title.imdbID)
    }

    func testFileProgressUsesPhysicalPathAndNeverEpisodeIdentity() throws {
        let info = try playback()
        let request = try CombinedLibraryFilePlayback.request(original(), version: version(), playback: info)
        let body = request.progressReport(position: 10, duration: 100, paused: false, ended: false,
                                          sourcePath: info.streamPath)
        XCTAssertEqual(body["mediaType"] as? String, "movie")
        XCTAssertEqual(body["itemId"] as? String, info.streamPath)
        for key in ["externalIds", "seriesId", "seasonNumber", "episodeNumber", "episodeName"] { XCTAssertNil(body[key]) }
        let query = request.streamMetadata(path: info.streamPath)
        XCTAssertEqual(query["itemId"], info.streamPath)
        for key in ["titleId", "seriesId", "tmdb", "imdb", "tvdb", "seasonNumber", "episodeNumber"] { XCTAssertNil(query[key]) }
    }

    func testCombinedVersionsRemainManualAndNeverBecomeBestEpisode() throws {
        let group = try JSONDecoder().decode(LibraryGroup.self, from: Data(#"{"id":"show","title":"Show","libraryType":"show","seasons":[{"seasonNumber":1,"episodes":[{"episodeNumber":2,"items":[{"id":"physical","episodes":[{"seasonNumber":1,"episodeNumber":1},{"seasonNumber":1,"episodeNumber":2}]}]}]}]}"#.utf8))
        let versions = LibraryVersions(group: group, libraryName: "Shows")
        XCTAssertEqual(versions.versions(season: 1, episode: 2).count, 1)
        XCTAssertNil(versions.best(season: 1, episode: 2))
    }

    func testMissingOrMalformedFileContractCannotBecomeSingleEpisode() throws {
        for raw in [
            #"{"itemId":"physical","streamPath":"localmedia:physical","progressScope":"file"}"#,
            #"{"itemId":"physical","streamPath":"localmedia:physical","progressScope":"file","combinedEpisodes":[{"seasonNumber":1,"episodeNumber":1}]}"#,
            #"{"itemId":"other","streamPath":"localmedia:physical","progressScope":"file","combinedEpisodes":[{"seasonNumber":1,"episodeNumber":1},{"seasonNumber":1,"episodeNumber":2}]}"#,
            #"{"itemId":"physical","streamPath":"localmedia:physical","progressScope":"file","combinedEpisodes":[{"seasonNumber":1,"episodeNumber":1},{"seasonNumber":1,"episodeNumber":1}]}"#
        ] {
            let info = try JSONDecoder().decode(LibraryPlaybackInfo.self, from: Data(raw.utf8))
            XCTAssertTrue(info.isCombinedFile)
            XCTAssertThrowsError(try CombinedLibraryFilePlayback.request(original(), version: version(), playback: info))
        }
    }

    func testSingleEpisodeLegacyPlaybackStillDecodesWithoutNewFields() throws {
        let info = try JSONDecoder().decode(LibraryPlaybackInfo.self,
            from: Data(#"{"itemId":"one","streamPath":"localmedia:one","durationSeconds":600}"#.utf8))
        XCTAssertFalse(info.isCombinedFile)
        XCTAssertNil(info.progressScope)
    }

    func testNewDescriptorCannotReuseOldCombinedConsentData() throws {
        let a = try playback()
        let b = try JSONDecoder().decode(LibraryPlaybackInfo.self, from: Data(#"{"itemId":"physical","streamPath":"localmedia:physical/replaced.mkv","progressScope":"file","combinedEpisodes":[{"seasonNumber":1,"episodeNumber":1},{"seasonNumber":1,"episodeNumber":3}]}"#.utf8))
        XCTAssertNotEqual(a, b)
    }

    func testAlreadyCancelledConsentDoesNotPresentOrAccept() async {
        let consent = CombinedLibraryFileConsent()
        let info: LibraryPlaybackInfo
        do { info = try playback() } catch { return XCTFail("synthetic descriptor did not decode") }
        let task = Task { await consent.confirm(info, on: UIViewController()) }
        task.cancel()
        let accepted = await task.value
        XCTAssertFalse(accepted)
    }
}
