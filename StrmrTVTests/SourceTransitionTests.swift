import XCTest
@testable import StrmrTV

@MainActor
final class SourceTransitionTests: XCTestCase {
    private func context(_ profile: String = "original") -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://example.invalid/proxy")!, profileID: profile,
                            clientID: "client", sessionToken: "synthetic-token-\(profile)")
    }

    @MainActor
    private final class ProgressAPI: PlayerProgressAPI {
        var current: SourceActionContext
        var contexts: [SourceActionContext] = []
        var bodies: [[String: Any]] = []
        var pending: CheckedContinuation<ProgressReply?, Never>?
        var hold = true
        var reply: ProgressReply?
        init(_ current: SourceActionContext) { self.current = current }
        func sourceContext() -> SourceActionContext { current }
        func reportOriginalProgress(_ body: [String: Any], context: SourceActionContext) async -> ProgressReply? {
            contexts.append(context)
            bodies.append(body)
            if hold { return await withCheckedContinuation { pending = $0 } }
            return reply
        }
        func finish() { let callback = pending; pending = nil; callback?.resume(returning: reply) }
    }

    @MainActor
    private final class Observer: PlayerProgressObserver {
        var replies = 0
        func progressDidReply(_ reply: ProgressReply, ended: Bool) { replies += 1 }
    }

    private func until(_ predicate: () -> Bool) async {
        for _ in 0..<1000 where !predicate() { await Task.yield() }
    }

    func testHistoryResetDrainsActualAdmittedProgressAndPermanentlyClosesFinishWrites() async throws {
        let api = ProgressAPI(context())
        api.reply = try JSONDecoder().decode(ProgressReply.self, from: Data(#"{"migrationRequested":true}"#.utf8))
        let observer = Observer()
        let writer = PlayerProgressWriter(viewer: context(), api: api, observer: observer)
        XCTAssertTrue(writer.submit(["itemId": "old-title"], ended: false))
        await until { api.pending != nil }
        XCTAssertNotNil(api.pending)
        var joined = false
        let reset = Task { try await writer.stopAndDrain(requireKnownAcknowledgements: true); joined = true }
        await until { !writer.accepting }
        XCTAssertFalse(writer.submit(["itemId": "old-title"], ended: true))
        XCTAssertFalse(joined)
        api.finish()
        try await reset.value
        XCTAssertTrue(joined)
        XCTAssertEqual(api.bodies.count, 1)
        XCTAssertEqual(observer.replies, 0, "A late old-source reply cannot auto-switch after the drain started")
        XCTAssertFalse(writer.submit(["itemId": "old-title"], ended: false))
    }

    func testUnknownProgressAcknowledgementDeniesResetAfterActualJoin() async {
        let api = ProgressAPI(context())
        let writer = PlayerProgressWriter(viewer: context(), api: api)
        XCTAssertTrue(writer.submit(["itemId": "old"], ended: false))
        await until { api.pending != nil }
        api.finish()
        await writer.waitForWrites()
        do { try await writer.stopAndDrain(requireKnownAcknowledgements: true); XCTFail("Unconfirmed write allowed reset") }
        catch { XCTAssertTrue(writer.hasUnconfirmedWrite) }
        XCTAssertFalse(writer.accepting)
    }

    func testNormalAlternativeDrainAlsoJoinsOldEndWriteBeforeNewPlayer() async throws {
        let api = ProgressAPI(context())
        let writer = PlayerProgressWriter(viewer: context(), api: api)
        XCTAssertTrue(writer.submit(["itemId": "old"], ended: true))
        await until { api.pending != nil }
        var canPresentNext = false
        let handoff = Task { try await writer.stopAndDrain(requireKnownAcknowledgements: false); canPresentNext = true }
        await until { !writer.accepting }
        XCTAssertFalse(canPresentNext)
        api.finish()
        try await handoff.value
        XCTAssertTrue(canPresentNext)
        XCTAssertFalse(writer.submit(["itemId": "old"], ended: true))
    }

    func testPlayerProgressNeverAdoptsAnotherProfileAfterAdmission() async {
        let api = ProgressAPI(context())
        let writer = PlayerProgressWriter(viewer: context(), api: api)
        XCTAssertTrue(writer.submit(["itemId": "physical-file"], ended: false))
        await until { api.pending != nil }
        api.current = context("new-profile")
        XCTAssertFalse(writer.submit(["itemId": "physical-file"], ended: false))
        api.finish()
        await writer.waitForWrites()
        XCTAssertEqual(api.contexts, [context()])
    }

    func testAlternativeChoicesUseHandoffPositionAndWrongContentAlwaysStartsAtZero() throws {
        let dialogPosition = 10.0
        let actualHandoff = 48.5
        XCTAssertNotEqual(dialogPosition, try ReleaseAlternativeStart.current.position(current: actualHandoff, wrongContent: false))
        XCTAssertEqual(try ReleaseAlternativeStart.current.position(current: actualHandoff, wrongContent: false), 48.5)
        XCTAssertEqual(try ReleaseAlternativeStart.rewindTen.position(current: actualHandoff, wrongContent: false), 38.5)
        XCTAssertEqual(try ReleaseAlternativeStart.rewindTen.position(current: 4, wrongContent: false), 0)
        for choice in ReleaseAlternativeStart.allCases {
            XCTAssertEqual(try choice.position(current: nil, wrongContent: true), 0)
        }
        XCTAssertThrowsError(try ReleaseAlternativeStart.current.position(current: .nan, wrongContent: false))
        XCTAssertEqual(try ReleaseAlternativeStart.beginning.position(current: nil, wrongContent: false), 0)
    }

    func testReadyGateRejectsQueuedWrongEpisodeAndFileOnlyRequests() throws {
        let title = DetailsTarget(titleID: "tvdb:series:1", name: "Synthetic", isMovie: false, year: nil,
            tmdbID: nil, imdbID: nil, tvdbID: "1", posterURL: nil, textPosterURL: nil,
            backdropURL: nil, logoURL: nil, overview: nil)
        let episode = PlaybackRequest.EpisodeInfo(season: 1, episode: 2, absolute: nil, name: nil, itemID: nil)
        var request = PlaybackRequest(title: title, episode: episode, start: nil)
        func status(_ state: String, _ episode: Int) throws -> PrequeueStatus {
            try JSONDecoder().decode(PrequeueStatus.self, from: Data("""
            {"prequeueId":"replacement","status":"\(state)","streamPath":"synthetic/file",
             "targetEpisode":{"seasonNumber":1,"episodeNumber":\(episode)}}
            """.utf8))
        }
        XCTAssertThrowsError(try ReleaseAlternativeHandoff.validate(status("queued", 2), id: "replacement", request: request))
        XCTAssertThrowsError(try ReleaseAlternativeHandoff.validate(status("ready", 1), id: "replacement", request: request))
        try ReleaseAlternativeHandoff.validate(status("ready", 2), id: "replacement", request: request)
        request.fileOnlyPlayback = true
        request.libraryVersion = nil
        request.following = [episode]
        XCTAssertFalse(request.allowsExternalSourceSelection)
        XCTAssertNil(request.nextEpisode)
        XCTAssertThrowsError(try ReleaseAlternativeHandoff.validate(status("ready", 2), id: "replacement", request: request))
    }

    func testSharedPrequeueBuilderGatesAutomaticLibrarySelectionOnActualCapability() {
        let original: [String: Any] = ["titleId": "tmdb:movie:1", "userId": "own", "skipHLS": true]
        for caller in ["ordinary", "prefetch", "prewarm"] {
            let modern = ContentLocalPreference.prequeueBody(original, supported: true)
            let legacy = ContentLocalPreference.prequeueBody(original, supported: false)
            XCTAssertEqual(modern["automaticLibrarySelection"] as? Bool, true, caller)
            XCTAssertNil(legacy["automaticLibrarySelection"], caller)
            XCTAssertEqual(modern["titleId"] as? String, original["titleId"] as? String)
            XCTAssertNil(modern["preferLocalFiles"], "The preference is server-side, not a fabricated prequeue field")
        }
    }

    func testCastCombinedFileProgressKeepsOriginalProfileAndPhysicalIdentity() throws {
        let title = DetailsTarget(titleID: "file:physical", name: "Combined", isMovie: true, year: nil,
            tmdbID: nil, imdbID: nil, tvdbID: nil, posterURL: nil, textPosterURL: nil,
            backdropURL: nil, logoURL: nil, overview: nil)
        var request = PlaybackRequest(title: title, episode: nil, start: nil)
        request.fileOnlyPlayback = true
        let playback = OriginalPlaybackProgress(request: request, path: "localmedia:physical/combined.mkv", context: context())
        let body = playback.body(position: 50, duration: 100, paused: false, ended: false)
        let phoneNow = context("new-profile")
        let wire = try playback.context.request("POST", path: "/api/users/\(APIClient.segment(playback.context.profileID))/history/progress", body: body)
        XCTAssertNotEqual(phoneNow, playback.context)
        XCTAssertEqual(wire.url?.path, "/proxy/api/users/original/history/progress")
        XCTAssertEqual(wire.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token-original")
        XCTAssertEqual(body["itemId"] as? String, playback.path)
        XCTAssertEqual(body["mediaType"] as? String, "movie")
        XCTAssertNil(body["episodeNumber"])
        XCTAssertNil(body["seriesId"])
    }
}
