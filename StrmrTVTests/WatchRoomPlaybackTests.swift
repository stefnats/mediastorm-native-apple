import Foundation
import XCTest
#if os(iOS)
@testable import StrmrMobile
#else
@testable import StrmrTV
#endif

/// Self-contained so the same SDK-facing cases are consumed by the hosted TV
/// suite and the selective iPhone unit target, without importing other fixtures.
@MainActor
private enum WatchRoomPlaybackFixture {
    static let id = "11111111-1111-4111-8111-111111111111"
    static func context(_ profile: String = "original") -> SourceActionContext {
        SourceActionContext(baseURL:URL(string:"https://synthetic.invalid/base")!,profileID:profile,
            clientID:"client",sessionToken:"synthetic-session",unlock:"original-proof")
    }
    static func target(episode: Bool = false) -> WatchRoomTarget {
        let title = DetailsTarget(titleID:episode ? "tmdb:series:55" : "tmdb:movie:55",name:"Synthetic",isMovie:!episode,
            year:2026,tmdbID:"55",imdbID:nil,tvdbID:nil,posterURL:nil,textPosterURL:nil,backdropURL:nil,logoURL:nil,overview:nil)
        return try! WatchRoomTarget(title:title,episode:episode ? .init(season:1,episode:2,absolute:nil,name:"Actual E02",itemID:nil) : nil)
    }
    static func fields(status: String = "paused", revision: Int64 = 8, position: Double = 42, waiting: Bool = false) -> [String:Any] {
        ["id":id,"creatorProfileId":"original","creatorName":"Original","title":"Synthetic","mediaType":"movie",
         "itemId":target().itemID,"params":target().params,"status":status,"waitingForReady":waiting,
         "position":position,"duration":100,"revision":revision,"anchorUpdatedAt":"2026-11-22T12:00:00Z",
         "expiresAt":"2026-11-23T12:00:00Z","members":[["profileId":"original","name":"Original","clientId":"client",
            "isCreator":true,"ready":true,"buffering":false,"joined":true,"present":true,"capabilities":WatchRoomWire.capabilities]]]
    }
    static func data(_ fields: [String:Any]? = nil) throws -> Data { try JSONSerialization.data(withJSONObject:fields ?? Self.fields()) }
    static func room() throws -> WatchRoom {
        let room = try JSONDecoder().decode(WatchRoom.self,from:data()); try room.validate(); return room
    }
}

@MainActor
private final class WatchRoomSourceTestAPI: WatchRoomSourceAPI {
    var context = WatchRoomPlaybackFixture.context()
    var requests: [URLRequest] = []
    var handler: ((URLRequest) async throws -> Data)?
    func isCurrent(_ context: SourceActionContext) -> Bool { context == self.context }
    func roomLocalPreference(_ id: String, context: SourceActionContext) async throws -> ContentLocalPreference {
        guard isCurrent(context) else { throw CancellationError() }
        return ContentLocalPreference(contentId:id,preferLocalFiles:true,localSourcePreferenceSupported:true)
    }
    func performWatchRoomRequest(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        if let handler { return try await handler(request) }
        return try WatchRoomPlaybackFixture.data()
    }
}

@MainActor
final class WatchRoomPlaybackTests: XCTestCase {
    func testExplicitOfficialOrderingIsTheSameCatalogueEpisodeButAlternateOrderingIsRejected() throws {
        let target = WatchRoomPlaybackFixture.target(episode:true)
        for order in ["official","default",""] {
            let episode = PlaybackRequest.EpisodeInfo(season:1,episode:2,absolute:nil,name:"E02",itemID:nil,
                numbering:.init(seriesId:target.title.titleID,ordering:order))
            XCTAssertEqual(try WatchRoomTarget(title:target.title,episode:episode).itemID,target.itemID)
        }
        for order in ["dvd","absolute","alternate"] {
            XCTAssertThrowsError(try WatchRoomTarget(title:target.title,episode:.init(season:1,episode:2,absolute:nil,name:nil,itemID:nil,
                numbering:.init(seriesId:target.title.titleID,ordering:order))))
        }
    }
    func testActualPreparationBodyUsesOwnViewerExactEpisodeAndOnlyAdvertisedLibraryExtension() throws {
        let context = WatchRoomPlaybackFixture.context(), target = WatchRoomPlaybackFixture.target(episode:true)
        let body = WatchRoomPreparation.body(target,context:context,automaticLibrary:true)
        XCTAssertEqual(body["userId"] as? String,"original"); XCTAssertEqual(body["clientId"] as? String,"client")
        XCTAssertEqual(body["seasonNumber"] as? Int,1); XCTAssertEqual(body["episodeNumber"] as? Int,2)
        XCTAssertEqual(body["automaticLibrarySelection"] as? Bool,true)
        XCTAssertNil(body["resource"]); XCTAssertNil(body["audioLanguage"]); XCTAssertNil(body["preferLocalFiles"])
        XCTAssertNil(WatchRoomPreparation.body(target,context:context,automaticLibrary:false)["automaticLibrarySelection"])
        let request = try WatchRoomPreparation.mediaRequest("local/actual.mkv",target:target,context:context)
        let query = try XCTUnwrap(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems)
        XCTAssertEqual(request.url?.path,"/base/api/video/stream")
        XCTAssertEqual(query.first{$0.name == "episodeNumber"}?.value,"2")
        XCTAssertEqual(query.first{$0.name == "clientId"}?.value,"client")
        XCTAssertEqual(request.value(forHTTPHeaderField:"X-Profile-Unlock"),"original-proof")
        let progress = OriginalPlaybackProgress(request:target.playback,path:"local/actual.mkv",context:context)
            .body(position:42,duration:100,paused:false,ended:false)
        XCTAssertEqual(progress["itemId"] as? String,target.itemID)
        XCTAssertFalse(target.playback.fileOnlyPlayback); XCTAssertTrue(target.playback.following.isEmpty)
    }
    func testDifferentResolvedEpisodeNeverReachesPlayerOrProducesFileE02Progress() throws {
        let target = WatchRoomPlaybackFixture.target(episode:true)
        func status(_ episode: Int) throws -> PrequeueStatus {
            try JSONDecoder().decode(PrequeueStatus.self,from:JSONSerialization.data(withJSONObject:[
                "prequeueId":"own","status":"ready","streamPath":"local/file.mkv",
                "targetEpisode":["seasonNumber":1,"episodeNumber":episode]]))
        }
        XCTAssertNoThrow(try WatchRoomPreparation.validate(status(2),id:"own",target:target))
        XCTAssertThrowsError(try WatchRoomPreparation.validate(status(3),id:"own",target:target))
        XCTAssertThrowsError(try WatchRoomPreparation.validate(status(2),id:"host-prequeue",target:target))
    }
    func testReadyFollowsActualLoadFiniteDurationAndVerifiedSeekAndNeverWritesState() async throws {
        let api = WatchRoomSourceTestAPI(), ledger = WatchRoomDepartures()
        let session = try WatchRoomSession(room:WatchRoomPlaybackFixture.room(),context:api.context,api:api,departures:ledger)
        let gate = WatchRoomEngineGate(session:session)
        var loaded = false, paused = false, position = 0.0
        api.handler = { request in
            XCTAssertTrue(loaded); XCTAssertTrue(paused); XCTAssertEqual(position,42)
            XCTAssertTrue(request.url!.path.hasSuffix("/ready"))
            return try WatchRoomPlaybackFixture.data()
        }
        try await gate.start(expectedDuration:100,load:{ loaded = true },duration:{ 100 },position:{ position },
            seek:{ position = $0 },pause:{ paused = true })
        XCTAssertTrue(gate.loaded); XCTAssertEqual(api.requests.count,1)
        XCTAssertFalse(api.requests.contains{$0.url!.path.hasSuffix("/state")})
    }
    func testHeldLoadCancelledByCloseCannotSendReadyOrPublishAnotherViewer() async throws {
        let api = WatchRoomSourceTestAPI(), session = try WatchRoomSession(room:WatchRoomPlaybackFixture.room(),context:api.context,api:api,departures:WatchRoomDepartures())
        let gate = WatchRoomEngineGate(session:session), entered = XCTestExpectation(description:"Actual load entered")
        var release: CheckedContinuation<Void,Never>?
        let loading = Task {
            do {
                try await gate.start(expectedDuration:100,load:{ await withCheckedContinuation { release = $0; entered.fulfill() } },
                    duration:{ 100 },position:{ 42 },seek:{ _ in XCTFail("A closed load must not seek") },pause:{})
                XCTFail("The closed load must not become ready")
            } catch {}
        }
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        gate.close(); api.context = WatchRoomPlaybackFixture.context("replacement")
        release?.resume(); release = nil; await loading.value
        XCTAssertFalse(gate.loaded); XCTAssertTrue(api.requests.isEmpty)
    }
    func testWrongDurationAndUnverifiedSeekNeverAdvertiseReadiness() async throws {
        let api = WatchRoomSourceTestAPI(), session = try WatchRoomSession(room:WatchRoomPlaybackFixture.room(),context:api.context,api:api,departures:WatchRoomDepartures())
        for duration in [Double.nan, Double.infinity, -1, 180] {
            let gate = WatchRoomEngineGate(session:session)
            do {
                try await gate.start(expectedDuration:100,load:{},duration:{ duration },position:{ 42 },seek:{ _ in },pause:{})
                XCTFail("Incompatible physical timeline must be rejected")
            } catch {}
        }
        var now = ContinuousClock.now
        let gate = WatchRoomEngineGate(session:session,now:{ now })
        do {
            try await gate.start(expectedDuration:100,load:{},duration:{ 100 },position:{ 0 },seek:{ _ in },pause:{},
                wait:{ now = now.advanced(by:.seconds(31)) })
            XCTFail("A requested seek without actual movement is not ready")
        } catch {}
        XCTAssertTrue(api.requests.isEmpty)
    }
    func testRemotePlayingPositionAdvancesOnlyFromReceiptAndAppliesWithoutStateEcho() async throws {
        let api = WatchRoomSourceTestAPI(), session = try WatchRoomSession(room:WatchRoomPlaybackFixture.room(),context:api.context,api:api,departures:WatchRoomDepartures())
        let now = ContinuousClock.now, gate = WatchRoomEngineGate(session:session,now:{ now })
        var position = 42.0, played = 0
        try await gate.start(expectedDuration:100,load:{},duration:{ 100 },position:{ position },seek:{ position = $0 },pause:{})
        api.handler = { _ in try WatchRoomPlaybackFixture.data(WatchRoomPlaybackFixture.fields(status:"playing",revision:9,position:50)) }
        await session.refresh()
        let read = WatchRoomObservation(session.room,received:now.advanced(by:.seconds(-2)))
        let applied = try await gate.apply(read,duration:{ 100 },position:{ position },seek:{ position = $0 },pause:{},play:{ played += 1 })
        XCTAssertTrue(applied); XCTAssertEqual(position,52,accuracy:0.001); XCTAssertEqual(played,1)
        XCTAssertFalse(api.requests.contains{$0.url!.path.hasSuffix("/state")})
    }
    func testReadyBarrierRemainsPausedAndRechecksLocalReadinessWithoutStateEcho() async throws {
        let api = WatchRoomSourceTestAPI(), session = try WatchRoomSession(room:WatchRoomPlaybackFixture.room(),context:api.context,api:api,departures:WatchRoomDepartures())
        let gate = WatchRoomEngineGate(session:session)
        try await gate.start(expectedDuration:100,load:{},duration:{ 100 },position:{ 42 },seek:{ _ in },pause:{})
        var waiting = WatchRoomPlaybackFixture.fields(status:"playing",revision:9,waiting:true)
        var members = try XCTUnwrap(waiting["members"] as? [[String:Any]]); members[0]["ready"] = false; waiting["members"] = members
        api.handler = { request in
            if request.url!.path.hasSuffix("/ready") { return try WatchRoomPlaybackFixture.data(WatchRoomPlaybackFixture.fields(status:"playing",revision:9,waiting:true)) }
            return try WatchRoomPlaybackFixture.data(waiting)
        }
        await session.refresh()
        var plays = 0, pauses = 0
        _ = try await gate.apply(session.observation,duration:{ 100 },position:{ 42 },seek:{ _ in },pause:{ pauses += 1 },play:{ plays += 1 })
        XCTAssertEqual(plays,0); XCTAssertGreaterThan(pauses,0)
        XCTAssertEqual(api.requests.filter{$0.url!.path.hasSuffix("/ready")}.count,2)
        XCTAssertFalse(api.requests.contains{$0.url!.path.hasSuffix("/state")})
    }
    func testClosingAnActualPreparationJoinsAdmittedPOSTAndNeverInventsPrequeueDelete() async throws {
        let api = WatchRoomSourceTestAPI(), preparation = WatchRoomPreparation(context:api.context,api:api)
        let entered = XCTestExpectation(description:"Actual own prequeue POST entered")
        var response: CheckedContinuation<Data,Error>?
        api.handler = { _ in try await withCheckedThrowingContinuation { response = $0; entered.fulfill() } }
        let preparing = Task { try? await preparation.prepare(WatchRoomPlaybackFixture.target()) }
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        let closing = Task { await preparation.closeAndDrain() }
        for _ in 0..<10 { await Task.yield() }
        response?.resume(returning:Data(#"{"prequeueId":"actual","status":"queued"}"#.utf8)); response = nil
        _ = await preparing.value; await closing.value
        XCTAssertEqual(api.requests.count,1); XCTAssertEqual(api.requests[0].httpMethod,"POST")
        XCTAssertEqual(api.requests[0].url!.path,"/base/api/playback/prequeue")
    }
    #if os(iOS)
    func testRoomOnlyMobileRoutePickerGatePreservesOrdinaryDefault() {
        let controls = MobileTransportView()
        XCTAssertTrue(controls.externalPlaybackAllowed)
        controls.setExternalPlaybackAllowed(false); XCTAssertFalse(controls.externalPlaybackAllowed)
        controls.setExternalPlaybackAllowed(true); XCTAssertTrue(controls.externalPlaybackAllowed)
    }
    #endif
}
