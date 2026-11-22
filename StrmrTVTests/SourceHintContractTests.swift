import Foundation
import XCTest
#if os(iOS)
@testable import StrmrMobile
#else
@testable import StrmrTV
#endif

@MainActor
enum SourceHintFixture {
    static let now = Date(timeIntervalSince1970:1_800_000_000)
    static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from:value) }
    static func raw(state: String = "not_found", complete: Bool = true, reason: String = "no_matching_candidates") -> [String:Any] {
        ["state":state,"complete":complete,"reason":reason,"providers":["selected-indexer"],
         "checkedAt":date(now.addingTimeInterval(-5)),"expiresAt":date(now.addingTimeInterval(300))]
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T { try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed)) }
    static func hint(_ value: [String:Any]? = nil) throws -> SourceAvailability { try decode(SourceAvailability.self,value ?? raw()) }
    static func title(_ hint: Any? = nil) throws -> Title {
        var raw: [String:Any] = ["id":"tmdb:movie:55","name":"Synthetic","mediaType":"movie","tmdbId":55,"year":2026,
            "cardSubtitle":"Chart context","watchState":"partial","unwatchedCount":3]
        raw["sourceAvailability"] = hint
        return try decode(Title.self,raw)
    }
    static func episode(_ hint: Any? = nil) throws -> Episode {
        var raw: [String:Any] = ["id":"actual-episode-id","name":"Actual E02","seasonNumber":1,"episodeNumber":2,
            "itemId":"official-progress-id","numbering":["seriesId":"tvdb:series:55","ordering":"official"]]
        raw["sourceAvailability"] = hint
        return try decode(Episode.self,raw)
    }
    static func context(_ profile: String = "original", proof: String = "original-proof") -> SourceActionContext {
        .init(baseURL:URL(string:"https://synthetic.invalid/base")!,profileID:profile,clientID:"client",sessionToken:"synthetic-session",unlock:proof)
    }
    static func body(_ request: URLRequest) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(request.httpBody)) as? [String:Any])
    }
    static func coverage() -> [String:Any] {
        ["state":"partial","foundEpisodes":1,"notFoundEpisodes":1,"unknownEpisodes":0,"catalogueComplete":false,
         "seasons":[["seasonNumber":1,"state":"partial","foundEpisodes":1,"notFoundEpisodes":1,"unknownEpisodes":0]]]
    }
}

@MainActor
final class SourceHintContractTests: XCTestCase {
    func testOptionalTitleAndEpisodeAnnotationsDecodeWithoutPoisoningCatalogueOnMalformedHint() throws {
        XCTAssertNil(try SourceHintFixture.title().sourceAvailability)
        var nullProviders = SourceHintFixture.raw(); nullProviders["providers"] = NSNull()
        let invalids: [Any] = [true,"unexpected",[1,2],["complete":"true","state":"not_found"],nullProviders]
        for invalid in invalids {
            let title = try SourceHintFixture.title(invalid), episode = try SourceHintFixture.episode(invalid)
            XCTAssertEqual(title.id,"tmdb:movie:55"); XCTAssertEqual(episode.id,"actual-episode-id")
            XCTAssertFalse(title.sourceAvailability?.presentation(at:SourceHintFixture.now).dimArtwork == true)
            XCTAssertFalse(episode.sourceAvailability?.presentation(at:SourceHintFixture.now).dimArtwork == true)
        }
        XCTAssertEqual(try SourceHintFixture.title(SourceHintFixture.raw()).sourceAvailability?.state,"not_found")
        XCTAssertEqual(try SourceHintFixture.episode(SourceHintFixture.raw(state:"found")).sourceAvailability?.state,"found")
    }
    func testListEntryAnnotationsRemainSeparateFromReleaseAndWatchMetadata() throws {
        let watch = try SourceHintFixture.decode(WatchlistItem.self,["id":"tmdb:movie:55","name":"Synthetic","mediaType":"movie",
            "availability":"coming_soon","watchState":"complete","sourceAvailability":SourceHintFixture.raw()])
        let current = try SourceHintFixture.decode(ContinueWatchingItem.self,["seriesId":"tmdb:movie:55","seriesTitle":"Synthetic",
            "percentWatched":37,"status":"released","sourceAvailability":SourceHintFixture.raw(state:"found")])
        XCTAssertEqual(watch.availability,"coming_soon"); XCTAssertEqual(watch.watchState,"complete")
        XCTAssertTrue(watch.sourceAvailability?.presentation(at:SourceHintFixture.now).dimArtwork == true)
        XCTAssertEqual(current.percentWatched,37); XCTAssertEqual(current.status,"released")
        XCTAssertEqual(current.sourceAvailability?.presentation(at:SourceHintFixture.now).kind,.candidate)
    }
    func testFreshnessRejectsFutureReversedOverlongAndExpiredEvidence() throws {
        let now = SourceHintFixture.now
        for (checked,expiry) in [(now.addingTimeInterval(1),now.addingTimeInterval(20)),(now,now),
            (now.addingTimeInterval(-86_401),now.addingTimeInterval(1)),(now.addingTimeInterval(-20),now)] {
            var raw = SourceHintFixture.raw(); raw["checkedAt"] = SourceHintFixture.date(checked); raw["expiresAt"] = SourceHintFixture.date(expiry)
            XCTAssertFalse(try SourceHintFixture.hint(raw).fresh(at:now))
            XCTAssertFalse(try SourceHintFixture.hint(raw).presentation(at:now).dimArtwork)
        }
    }
    func testFreshCompleteRecognizedNegativeIsTheOnlyRemoteMissingState() throws {
        for (state,complete,reason,missing) in [("not_found",true,"no_matching_candidates",true),("not_found",true,"reported_candidates",true),
            ("not_found",false,"no_matching_candidates",false),("not_found",true,"network_error",false),("unknown",true,"no_matching_candidates",false),
            ("not_found",true,"recheck_queued",false),("found",true,"no_matching_candidates",false)] {
            XCTAssertEqual(try SourceHintFixture.hint(SourceHintFixture.raw(state:state,complete:complete,reason:reason)).presentation(at:SourceHintFixture.now).dimArtwork,missing)
        }
        var noProviders = SourceHintFixture.raw(); noProviders["providers"] = [String]()
        XCTAssertTrue(try SourceHintFixture.hint(noProviders).presentation(at:SourceHintFixture.now).dimArtwork)
        noProviders["providers"] = nil
        XCTAssertTrue(try SourceHintFixture.hint(noProviders).presentation(at:SourceHintFixture.now).dimArtwork)
        noProviders["complete"] = false
        XCTAssertFalse(try SourceHintFixture.hint(noProviders).presentation(at:SourceHintFixture.now).dimArtwork)
    }
    func testFoundIsACandidateAndCheckedLocalFileRequiresItsExactEvidenceShape() throws {
        XCTAssertEqual(try SourceHintFixture.hint(SourceHintFixture.raw(state:"found",complete:false)).presentation(at:SourceHintFixture.now).kind,.candidate)
        var local = SourceHintFixture.raw(state:"found",reason:"local_file_checked")
        local["sourceType"] = "local"; local["providers"] = [String]()
        local["expiresAt"] = SourceHintFixture.date(SourceHintFixture.now.addingTimeInterval(100))
        XCTAssertEqual(try SourceHintFixture.hint(local).presentation(at:SourceHintFixture.now).kind,.local)
        for invalid in ["providers","sourceType","interval"] {
            var raw = local
            if invalid == "providers" { raw["providers"] = ["provider"] }
            if invalid == "sourceType" { raw["sourceType"] = "remote" }
            if invalid == "interval" { raw["expiresAt"] = SourceHintFixture.date(SourceHintFixture.now.addingTimeInterval(121)) }
            XCTAssertEqual(try SourceHintFixture.hint(raw).presentation(at:SourceHintFixture.now).kind,.unknown)
        }
    }
    func testPartialCoverageCountsSeasonsAndCatalogueCompletenessCannotBecomeAbsence() throws {
        var raw = SourceHintFixture.raw(state:"found"); raw["episodeCoverage"] = SourceHintFixture.coverage()
        XCTAssertEqual(try SourceHintFixture.hint(raw).presentation(at:SourceHintFixture.now).kind,.partial)
        raw["state"] = "not_found"
        XCTAssertFalse(try SourceHintFixture.hint(raw).presentation(at:SourceHintFixture.now).dimArtwork)
        for key in ["catalogueComplete","foundEpisodes"] {
            var coverage = SourceHintFixture.coverage()
            if key == "catalogueComplete" { coverage[key] = true } else { coverage[key] = 2 }
            raw["episodeCoverage"] = coverage
            let title = try SourceHintFixture.title(raw)
            XCTAssertNil(title.sourceAvailability)
        }
    }
    func testTitleDemandUsesExactOriginalPathUniqueCoordinatesVersionAndBodyLimit() throws {
        let coordinate = SourceTitleCoordinate(titleId:"tmdb:movie:55",mediaType:"movie"), version: Int64 = 9_007_199_254_740_993
        let request = try SourceHintsWire.titles(SourceHintFixture.context(),view:"view_A-1",version:version,values:[coordinate])
        let body = try SourceHintFixture.body(request)
        XCTAssertEqual(request.url?.path,"/base/api/users/original/source-availability/titles/view_A-1")
        XCTAssertEqual(request.httpMethod,"PUT"); XCTAssertEqual((body["version"] as? NSNumber)?.int64Value,version)
        XCTAssertEqual(request.value(forHTTPHeaderField:"X-Profile-Unlock"),"original-proof")
        XCTAssertEqual(Set(body.keys),["version","titles"])
        XCTAssertThrowsError(try SourceHintsWire.titles(SourceHintFixture.context(),view:"../other",version:1,values:[coordinate]))
        XCTAssertThrowsError(try SourceHintsWire.titles(SourceHintFixture.context(),view:"v",version:1,values:[coordinate,coordinate]))
        XCTAssertThrowsError(try SourceHintsWire.request(SourceHintFixture.context(),kind:"titles",view:"v",body:["huge":String(repeating:"x",count:33_000)]))
    }
    func testEpisodeDemandKeepsActualEpisodeIDsAndSingleDeliveredNumbering() throws {
        let episode = try SourceHintFixture.episode(), coordinate = SourceEpisodeCoordinate(episode)
        let request = try SourceHintsWire.episodes(SourceHintFixture.context(),view:"v",version:2,titleID:"tmdb:series:55",numbering:episode.numbering,values:[coordinate])
        let body = try SourceHintFixture.body(request), episodes = try XCTUnwrap(body["episodes"] as? [[String:Any]])
        XCTAssertEqual(episodes.first?["episodeId"] as? String,"actual-episode-id")
        XCTAssertEqual((body["numbering"] as? [String:String])?["seriesId"],"tvdb:series:55")
        XCTAssertEqual((body["numbering"] as? [String:String])?["ordering"],"official")
        XCTAssertNil(body["query"]); XCTAssertNil(body["provider"])
        XCTAssertThrowsError(try SourceHintsWire.episodes(SourceHintFixture.context(),view:"v",version:2,titleID:"tmdb:series:55",numbering:nil,values:[coordinate]))
    }
    func testEmptyHigherVersionReleasesNeedNoInventedTitleOrEpisodeMetadata() throws {
        let context = SourceHintFixture.context()
        let titles = try SourceHintFixture.body(SourceHintsWire.titles(context,view:"v",version:3,values:[]))
        let episodes = try SourceHintFixture.body(SourceHintsWire.episodes(context,view:"v",version:4,titleID:nil,numbering:nil,values:[]))
        XCTAssertEqual((titles["titles"] as? [Any])?.count,0)
        XCTAssertEqual(Set(episodes.keys),["version","episodes"]); XCTAssertEqual((episodes["episodes"] as? [Any])?.count,0)
        XCTAssertEqual((episodes["version"] as? NSNumber)?.int64Value,4)
    }
    func testUnsupportedDisabledAndMalformedRepliesNeverProveMissing() throws {
        let disabled = try SourceHintsWire.titleReply(JSONSerialization.data(withJSONObject:["enabled":false,"version":1,"items":[]]),version:1,requested:[])
        XCTAssertFalse(disabled.enabled)
        let coordinate = SourceTitleCoordinate(titleId:"tmdb:movie:55",mediaType:"movie")
        let reply: [String:Any] = ["enabled":true,"version":2,"items":[["titleId":coordinate.titleId,"mediaType":"movie","sourceAvailability":true]]]
        let value = try SourceHintsWire.titleReply(JSONSerialization.data(withJSONObject:reply),version:2,requested:[coordinate])
        XCTAssertNil(value.items.first?.sourceAvailability)
        XCTAssertThrowsError(try SourceHintsWire.titleReply(JSONSerialization.data(withJSONObject:reply),version:1,requested:[coordinate]))
    }
}
