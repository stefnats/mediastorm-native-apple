import XCTest
@testable import StrmrTV

@MainActor
final class LiveStationGroupsTests: XCTestCase {
    private let first = "station:8fb157ee01b29cf5af3b8d7f"
    private let second = "station:0123456789abcdef01234567"
    private func channel(_ id: String, source: String, station: String?, variants: Int = 1, name: String = "RTL HD") throws -> LiveChannel {
        var raw: [String: Any] = ["id": id, "name": name, "url": "https://provider.invalid/never-open/\(source)",
            "sourceId": source, "sourceName": source, "tvgId": "RTL.de"]
        if let station { raw["stationId"] = station; raw["stationName"] = "RTL"; raw["stationVariants"] = variants }
        return try JSONDecoder().decode(LiveChannel.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func testExactBackendStationIdentityGroupsAllLoadedVariantsWithoutReplacingSource() throws {
        let a = try channel("one", source: "source-a", station: first, variants: 3)
        let b = try channel("two", source: "source-b", station: first, variants: 3)
        let sections = LiveStationGroups.sections([a, b])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].stationID, first)
        XCTAssertEqual(sections[0].channels, [a, b])
        XCTAssertEqual(sections[0].scope, "2 of 3 source variants loaded")
    }
    func testSameNameDifferentOrMissingStationNeverBecomesOneStationHeader() throws {
        let rows = try [channel("one", source: "a", station: first), channel("two", source: "b", station: second),
                        channel("three", source: "c", station: nil)]
        let sections = LiveStationGroups.sections(rows)
        XCTAssertTrue(sections.allSatisfy { $0.stationID == nil })
        XCTAssertEqual(sections.flatMap(\.channels), rows)
    }
    func testSameRawChannelIDAcrossSourcesRemainsIndividuallySelectable() throws {
        let a = try channel("shared", source: "a", station: first, variants: 2)
        let b = try channel("shared", source: "b", station: first, variants: 2)
        let members = LiveStationGroups.sections([a, b, a])[0].members
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(Set(members.map(\.id)).count, 2)
        XCTAssertEqual(members.map(\.channel), [a, b])
    }
    func testOnlyExactServerStationFormatCanGroup() throws {
        for invalid in ["RTL", "station:abc", " station:8fb157ee01b29cf5af3b8d7f", "station:8FB157EE01B29CF5AF3B8D7F"] {
            let rows = try [channel("a", source: "a", station: invalid, variants: 5), channel("b", source: "b", station: invalid, variants: 5)]
            XCTAssertTrue(LiveStationGroups.sections(rows).allSatisfy { $0.stationID == nil })
        }
    }
    func testSingleLoadedVariantStillExplainsUnloadedSources() throws {
        let item = try channel("one", source: "a", station: first, variants: 4)
        let before = LiveStationGroups.sections([item])
        XCTAssertEqual(before[0].scope, "1 of 4 source variants loaded")
        let after = LiveStationGroups.sections([item, try channel("two", source: "b", station: first, variants: 4)])
        XCTAssertEqual(before[0].id, after[0].id)
        XCTAssertEqual(after[0].scope, "2 of 4 source variants loaded")
    }
    func testLegacyChannelStillDecodesAndKeepsItsGuideKey() throws {
        let legacy = try channel("legacy", source: "source", station: nil)
        XCTAssertNil(legacy.stationId)
        XCTAssertNil(legacy.stationVariants)
        XCTAssertEqual(legacy.guideKey, "RTL.de")
        XCTAssertEqual(LiveStationGroups.sections([legacy])[0].channels, [legacy])
    }
}
