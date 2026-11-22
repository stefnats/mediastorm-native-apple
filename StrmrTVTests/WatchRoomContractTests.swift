import Foundation
import XCTest
@testable import StrmrTV

@MainActor
enum WatchRoomFixture {
    static let id = "11111111-1111-4111-8111-111111111111"
    static let inviteID = "22222222-2222-4222-8222-222222222222"
    static func target(episode: Bool = false) -> WatchRoomTarget {
        let title = DetailsTarget(titleID:episode ? "tmdb:series:55" : "tmdb:movie:55",name:"Synthetic",isMovie:!episode,
            year:2026,tmdbID:"55",imdbID:nil,tvdbID:nil,posterURL:nil,textPosterURL:nil,backdropURL:nil,logoURL:nil,overview:nil)
        return try! WatchRoomTarget(title:title,episode:episode ? .init(season:1,episode:2,absolute:nil,name:"Actual E02",itemID:nil) : nil)
    }
    static func fields(joined: Bool = true, status: String = "paused", revision: Int64 = 8,
                       position: Double = 42, duration: Double = 100, waiting: Bool = false, episode: Bool = false) -> [String:Any] {
        let target = target(episode:episode)
        var member: [String:Any] = ["profileId":"original","name":"Original","isCreator":joined,"ready":joined,
            "buffering":false,"joined":joined,"present":joined,"capabilities":WatchRoomWire.capabilities]
        if joined { member["clientId"] = "client" }
        return ["id":id,"creatorProfileId":joined ? "original" : "host","creatorName":joined ? "Original" : "Host","title":"Synthetic",
            "mediaType":episode ? "episode" : "movie","itemId":target.itemID,"params":target.params,"status":status,
            "waitingForReady":waiting,"position":position,"duration":duration,"revision":revision,
            "anchorUpdatedAt":"2026-11-22T12:00:00Z","expiresAt":ISO8601DateFormatter().string(from:Date.now.addingTimeInterval(86_400)),"members":[member]]
    }
    static func data(_ fields: [String:Any]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject:fields ?? Self.fields())
    }
    static func room(_ fields: [String:Any]? = nil) throws -> WatchRoom {
        let room = try JSONDecoder().decode(WatchRoom.self,from:data(fields)); try room.validate(); return room
    }
    static func invite() throws -> WatchRoomAccountInvite {
        try JSONDecoder().decode(WatchRoomAccountInvite.self,from:JSONSerialization.data(withJSONObject:[
            "id":inviteID,"roomId":id,"status":"pending","expiresAt":ISO8601DateFormatter().string(from:Date.now.addingTimeInterval(86_400)),"title":"Synthetic"]))
    }
}

@MainActor
final class WatchRoomTestAPI: WatchRoomsAPI {
    var context = PersonalTasteFixture.context()
    var requests: [URLRequest] = []
    var handler: ((URLRequest) async throws -> Data)?
    func isCurrent(_ context: SourceActionContext) -> Bool { context == self.context }
    func performWatchRoomRequest(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        if let handler { return try await handler(request) }
        if request.url?.path.hasSuffix("/leave") == true || request.url?.path.hasSuffix("/end") == true { return Data() }
        return try WatchRoomFixture.data()
    }
}

@MainActor
final class WatchRoomContractTests: XCTestCase {
    func testActualGoPendingMemberCanOmitClientIDWithoutFabricatingJoin() throws {
        let room = try WatchRoomFixture.room(WatchRoomFixture.fields(joined:false))
        XCTAssertFalse(room.members[0].joined); XCTAssertNil(room.members[0].clientId)
        var fields = WatchRoomFixture.fields(joined:true)
        var members = try XCTUnwrap(fields["members"] as? [[String:Any]]); members[0]["clientId"] = nil; fields["members"] = members
        XCTAssertThrowsError(try WatchRoomFixture.room(fields))
    }
    func testEpisodeTargetAndRoomItemIDCannotBecomeFalseE02Progress() throws {
        let room = try WatchRoomFixture.room(WatchRoomFixture.fields(episode:true))
        let target = try WatchRoomTarget(room:room)
        XCTAssertEqual(target.season,1); XCTAssertEqual(target.episode,2)
        XCTAssertEqual(target.playback.progressItemID,"tmdb:series:55:S01E02")
        var wrong = WatchRoomFixture.fields(episode:true); wrong["itemId"] = "tmdb:series:55:S01E03"
        XCTAssertThrowsError(try WatchRoomFixture.room(wrong))
    }
    func testUnsupportedSourceSelectorsAndAlternateOrderingNeverEnterRoomParams() throws {
        var fields = WatchRoomFixture.fields(), params = WatchRoomFixture.target().params
        params["profileId"] = "another-profile"; fields["params"] = params
        XCTAssertThrowsError(try WatchRoomFixture.room(fields))
        let target = WatchRoomFixture.target(episode:true)
        let ep = PlaybackRequest.EpisodeInfo(season:1,episode:2,absolute:nil,name:nil,itemID:nil,
            numbering:.init(seriesId:target.title.titleID,ordering:"dvd"))
        XCTAssertThrowsError(try WatchRoomTarget(title:target.title,episode:ep))
        XCTAssertThrowsError(try WatchRoomTarget(title:target.title,episode:nil))
    }
    func testCreateWireCarriesCoordinatesAndCapabilitiesNotMediaOrLanguage() throws {
        let context = PersonalTasteFixture.context(), target = WatchRoomFixture.target(episode:true)
        let body = try WatchRoomWire.createBody(target,context:context,invitees:["other-profile"])
        let request = try WatchRoomWire.request(context,method:"POST",body:body)
        let sent = try PersonalTasteFixture.body(request)
        XCTAssertEqual(request.url?.path,"/base/api/users/original/watch-rooms")
        XCTAssertEqual(request.value(forHTTPHeaderField:"X-Profile-Unlock"),"original-proof")
        XCTAssertEqual(sent["itemId"] as? String,target.itemID)
        XCTAssertEqual(sent["mediaType"] as? String,"episode")
        let params = try XCTUnwrap(sent["params"] as? [String:String])
        XCTAssertNil(params["resource"]); XCTAssertNil(params["streamPath"]); XCTAssertNil(params["audioLanguage"])
        XCTAssertNil(params["token"]); XCTAssertNil(params["profileId"])
        XCTAssertEqual((sent["capabilities"] as? [String:Any])?["protocolVersion"] as? Int,1)
    }
    func testInt64RevisionRemainsExactInActualStateBody() throws {
        let room = try WatchRoomFixture.room(WatchRoomFixture.fields(revision:9_007_199_254_740_993))
        let body = try WatchRoomWire.stateBody(room,paused:true,position:12,duration:100)
        XCTAssertEqual(body["expectedRevision"] as? Int64,9_007_199_254_740_993)
        for position in [-1, Double.nan, Double.infinity, 101] {
            XCTAssertThrowsError(try WatchRoomWire.stateBody(room,paused:false,position:position,duration:100))
        }
    }
    func testDecoratedPositionUsesOnlyLocalReceiptElapsedNeverOldServerAnchor() throws {
        let room = try WatchRoomFixture.room(WatchRoomFixture.fields(status:"playing",position:42))
        let received = ContinuousClock.now, observation = WatchRoomObservation(room,received:received)
        XCTAssertEqual(observation.position(now:received.advanced(by:.seconds(2))),44,accuracy:0.0001)
        let waiting = try WatchRoomFixture.room(WatchRoomFixture.fields(status:"playing",waiting:true))
        XCTAssertEqual(WatchRoomObservation(waiting,received:received).position(now:received.advanced(by:.seconds(2))),42)
    }
    func testTransportRejectsDifferentRoomOrEpisodeBeforeAdoption() throws {
        let transport = WatchRoomTransport(context:PersonalTasteFixture.context(),api:WatchRoomTestAPI())
        XCTAssertThrowsError(try transport.decodeRoom(WatchRoomFixture.data(),expectedID:WatchRoomFixture.inviteID))
        XCTAssertThrowsError(try transport.decodeRoom(WatchRoomFixture.data(),expectedTarget:WatchRoomFixture.target(episode:true)))
    }
}
