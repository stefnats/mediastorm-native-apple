import XCTest
@testable import StrmrTV

@MainActor
final class LiveStationPresentationTests: XCTestCase {
    func testActualPageBodyRequestsGroupingWithoutLosingOriginalFilters() {
        let body = APIClient.liveChannelsBody(profileID: "profile", sourceID: "source", categories: ["News"],
            favoritesOnly: true, search: "RTL", favoriteIDs: ["source:raw"], offset: 250, limit: 250)
        XCTAssertEqual(body["groupByStation"] as? Bool, true)
        XCTAssertEqual(body["profileId"] as? String, "profile")
        XCTAssertEqual(body["sourceId"] as? String, "source")
        XCTAssertEqual(body["offset"] as? Int, 250)
        XCTAssertEqual(body["favoriteIds"] as? [String], ["source:raw"])
        XCTAssertEqual(body["categories"] as? [String], ["News"])
        XCTAssertEqual(body["filter"] as? String, "RTL")
    }
    func testCollapseChangesPresentationOnlyAndRestoresEveryRealSource() throws {
        let raw = #"{"id":"source:raw","name":"RTL","url":"https://provider.invalid/never-open","sourceId":"source","stationId":"station:0123456789abcdef01234567","stationName":"RTL","stationVariants":3,"tvgId":"rtl.de"}"#
        let channel = try JSONDecoder().decode(LiveChannel.self, from: Data(raw.utf8))
        let section = LiveStationGroups.sections([channel])[0]
        let store = LiveStore(profileID: "synthetic-profile")
        XCTAssertFalse(store.isCollapsed(section))
        store.toggleStation(section)
        XCTAssertTrue(store.isCollapsed(section))
        XCTAssertEqual(section.channels, [channel])
        store.toggleStation(section)
        XCTAssertFalse(store.isCollapsed(section))
        let query = APIClient.shared.liveStartQuery(section.channels[0], programTitle: nil)
        XCTAssertEqual(query["url"], channel.url)
        XCTAssertEqual(query["sourceId"], "source")
        XCTAssertEqual(query["channelId"], "source:raw")
        XCTAssertEqual(channel.guideKey, "rtl.de")
    }
    func testExistingStremioPickSurvivesStationPresentation() throws {
        let raw = #"{"id":"addon:channel","name":"Sports","url":"https://addon.invalid/stream/tv/channel.json","sourceId":"addon","stationId":"station:0123456789abcdef01234567","stationVariants":2}"#
        let channel = try JSONDecoder().decode(LiveChannel.self, from: Data(raw.utf8))
        let selected = LiveSourceChoice(channel: channel, streams: []).channel(streamIndex: 7)
        let grouped = LiveStationGroups.sections([selected])[0].channels[0]
        XCTAssertTrue(grouped.hasStremioSources)
        XCTAssertEqual(grouped.stremioStreamIndex, 7)
        XCTAssertEqual(APIClient.shared.liveStartQuery(grouped, programTitle: nil)["stremioStreamIndex"], "7")
        XCTAssertEqual(grouped.url, channel.url)
    }
}
