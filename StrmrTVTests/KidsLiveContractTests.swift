import XCTest
@testable import StrmrTV

@MainActor
final class KidsLiveContractTests: XCTestCase {
    private func context() -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://server.invalid/prefix")!, profileID: "child", clientID: "actual-client",
            sessionToken: "synthetic-original", unlock: "synthetic-unlock")
    }
    private func raw() -> [String: Any] {
        ["sessionId": "owned-session", "playlistUrl": "/video/hls/owned-session/stream.m3u8?profileId=child",
         "programmeEndsAt": "2026-11-22T12:00:00Z", "programmeRemainingMillis": 1000,
         "isDirect": false, "timeshiftWindowSeconds": 0,
         "programme": ["title": "Synthetic programme", "startsAt": "2026-11-22T11:30:00Z", "endsAt": "2026-11-22T12:00:00Z",
             "age": 6, "country": "DE", "classificationBasis": "selected_guide_claim",
             "guide": ["id": "chosen-guide", "type": "xmltv", "name": "Parent-selected guide", "observedAt": "2026-11-22T11:00:00Z"]]]
    }
    private func decode(_ raw: [String: Any]) throws -> KidsLiveStartReply {
        try JSONDecoder().decode(KidsLiveStartReply.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func testActualBackendProgrammeShapeAndOriginalBasepathMediaCredentials() throws {
        let opened = try KidsLiveOpened.validate(decode(raw()), context: context(), requestedAt: .seconds(10), now: .milliseconds(10500))
        XCTAssertEqual(opened.deadline, .seconds(11))
        XCTAssertEqual(opened.sessionID, "owned-session")
        XCTAssertEqual(opened.url.host, "server.invalid")
        XCTAssertEqual(opened.url.path, "/prefix/api/video/hls/owned-session/stream.m3u8")
        let query = URLComponents(url: opened.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "profileId" }?.value, "child")
        XCTAssertEqual(query.first { $0.name == "profileUnlock" }?.value, "synthetic-unlock")
        XCTAssertEqual(query.first { $0.name == "token" }?.value, "synthetic-original")
        XCTAssertEqual(opened.headers["X-Client-ID"], "actual-client")
        XCTAssertTrue(opened.programme.claim.contains("Parent-selected guide"))
    }

    func testActualStartRequestContainsOnlyCatalogueIdentityNotProviderOrRating() throws {
        let request = try APIClient.kidsLiveStartRequest("source:exact/channel", context: context())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/prefix/api/live/kids/hls/start")
        let values = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(Set(values.map(\.name)), ["profileId", "channelId", "clientId", "target"])
        XCTAssertEqual(values.first { $0.name == "channelId" }?.value, "source:exact/channel")
        XCTAssertEqual(values.first { $0.name == "target" }?.value, "native")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-original")
    }

    func testDirectTimeshiftWrongPlaylistAndProgrammeDeadlinesCannotBeAdopted() throws {
        for (key, value) in [("isDirect", true as Any), ("timeshiftWindowSeconds", 180 as Any),
            ("playlistUrl", "https://elsewhere.invalid/file.m3u8" as Any),
            ("playlistUrl", "/video/hls/foreign/stream.m3u8" as Any),
            ("playlistUrl", "/video/hls/owned-session/stream.m3u8?profileId=other" as Any),
            ("programmeRemainingMillis", 0 as Any), ("programmeEndsAt", "2026-11-22T12:01:00Z" as Any)] {
            var invalid = raw(); invalid[key] = value
            XCTAssertThrowsError(try KidsLiveOpened.validate(decode(invalid), context: context(), requestedAt: .zero, now: .zero), key)
        }
        XCTAssertThrowsError(try KidsLiveOpened.validate(decode(raw()), context: context(), requestedAt: .zero, now: .seconds(1)))
    }

    func testProviderFreeCatalogueAndSelectedGuideClaimNeverInventAnAge() throws {
        let body = #"{"channels":[{"id":"source:one","name":"Allowed","programmeState":"unknown","programmeReason":"No unique guide age"}],"total":1}"#
        let reply = try JSONDecoder().decode(KidsLiveChannelsReply.self, from: Data(body.utf8))
        XCTAssertFalse(reply.channels[0].selectable)
        XCTAssertNil(reply.channels[0].programme)
        let policy = try JSONDecoder().decode(KidsLivePolicy.self, from: Data(#"{"enabled":true,"country":"DE","maximumAge":6,"guideSourceId":"selected"}"#.utf8))
        XCTAssertTrue(policy.configured)
        let unknown = try JSONDecoder().decode(KidsLivePolicy.self, from: Data(#"{"enabled":true,"country":"DE","maximumAge":6,"guideSourceId":""}"#.utf8))
        XCTAssertFalse(unknown.configured)
    }
}
