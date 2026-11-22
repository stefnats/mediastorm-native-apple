import CoreGraphics
import Foundation
import XCTest
#if os(iOS)
@testable import StrmrMobile
#else
@testable import StrmrTV
#endif

@MainActor
final class SourceHintsFixtureAPI: SourceHintsAPI {
    var context = SourceHintFixture.context()
    var requests: [URLRequest] = []
    var handler: ((URLRequest) async throws -> Data)?
    var inFlight = 0
    var maximumInFlight = 0
    func isCurrent(_ context: SourceActionContext) -> Bool { self.context == context }
    static func reply(_ request: URLRequest, hint: [String:Any]? = nil) throws -> Data {
        let body = try SourceHintFixture.body(request), titles = request.url!.path.contains("/titles/")
        let input = try XCTUnwrap(body[titles ? "titles" : "episodes"] as? [[String:Any]])
        let rows = input.map { value -> [String:Any] in var row = value; row["sourceAvailability"] = hint ?? SourceHintFixture.raw(state:"found"); return row }
        return try JSONSerialization.data(withJSONObject:["enabled":true,"version":body["version"]!,"items":rows])
    }
    func sourceHints(_ request: URLRequest) async throws -> Data {
        requests.append(request); inFlight += 1; maximumInFlight = max(maximumInFlight,inFlight)
        defer { inFlight -= 1 }
        if let handler { return try await handler(request) }
        return try Self.reply(request)
    }
}

@MainActor
final class VisibleSourceHintsTests: XCTestCase {
    private let page = CGRect(x:0,y:0,width:200,height:200)
    private func title(_ id: String = "tmdb:movie:55") -> SourceTitleCoordinate { .init(titleId:id,mediaType:"movie") }
    private func record(_ coordinate: VisibleSourceCoordinate, id: UUID = UUID(), x: Double = 0, y: Double = 0, order: Int = 0) -> VisibleSourceRecord {
        .init(id:id,coordinate:coordinate,rect:CGRect(x:x,y:y,width:60,height:90),order:order)
    }
    private func until(_ predicate: () -> Bool) async { for _ in 0..<1000 { if !predicate() { await Task.yield() } } }
    private func makeOwner(_ api: SourceHintsFixtureAPI, wait: ((Duration) async throws -> Void)? = nil) -> VisibleSourceHints {
        VisibleSourceHints(context:api.context,api:api,viewID:"test_view",coalesce:.zero,wait:wait ?? { duration in
            if duration == .zero { await Task.yield() } else { try await Task.sleep(for:.seconds(3600)) }
        })
    }
    private func show(_ owner: VisibleSourceHints, _ coordinate: VisibleSourceCoordinate, id: UUID = UUID()) {
        owner.setPage(page,visible:true); owner.record(record(coordinate,id:id)); owner.setActive(true)
    }
    func testActualViewportAdapterExcludesLazyPreloadAndOffscreenRowsOnBothAxes() {
        let visible = record(.title(title())), horizontalPreload = record(.title(title("preloaded")),x:500), verticalRow = record(.title(title("offscreen-row")),y:500)
        let selection = SourceHintViewport.select([visible,horizontalPreload,verticalRow],page:page,active:true)
        XCTAssertEqual(selection.titles,[title()])
        XCTAssertTrue(SourceHintViewport.select([visible],page:page,active:false).titles.isEmpty)
        XCTAssertTrue(SourceHintViewport.select([visible],page:.null,active:true).titles.isEmpty)
    }
    func testTitleViewportDeduplicatesAndCaps24WithoutChangingCardOrder() {
        let records = (0..<30).map { record(.title(title("title-\($0)")),order:$0) }
        let copy = records
        let result = SourceHintViewport.select(records+[records[0]],page:page,active:true)
        XCTAssertEqual(result.titles,(0..<24).map{title("title-\($0)")}); XCTAssertEqual(records,copy)
    }
    func testEpisodeViewportCaps12AndRetiresPreviousSeasonOrNumbering() {
        let first = EpisodeNumbering(seriesId:"tvdb:series:55",ordering:"official"), second = EpisodeNumbering(seriesId:"tvdb:series:55",ordering:"dvd")
        let records = (1...20).map { n in record(.episode(titleID:"tmdb:series:55",numbering:first,value:.init(episodeId:"real-\(n)",seasonNumber:1,episodeNumber:n)),order:n) }
        let result = SourceHintViewport.select(records,page:page,active:true)
        XCTAssertEqual(result.episodes.count,12); XCTAssertEqual(result.episodes.first?.episodeId,"real-1")
        let next = record(.episode(titleID:"tmdb:series:55",numbering:second,value:.init(episodeId:"actual-dvd-id",seasonNumber:2,episodeNumber:3)))
        let replaced = SourceHintViewport.select([next],page:page,active:true)
        XCTAssertEqual(replaced.numbering,second); XCTAssertEqual(replaced.episodes.map(\.episodeId),["actual-dvd-id"])
        XCTAssertFalse(replaced.episodes.contains(result.episodes[0]))
    }
    func testHeroContributesOnlyItsCurrentActuallyVisibleCoordinate() throws {
        let card = HomeCard(try SourceHintFixture.title())
        XCTAssertNil(SourceHintAdapters.hero(card,visible:false))
        let coordinate = try XCTUnwrap(SourceHintAdapters.hero(card,visible:true))
        XCTAssertEqual(SourceHintViewport.select([record(coordinate)],page:page,active:true).titles,[title()])
        XCTAssertTrue(SourceHintViewport.select([record(coordinate,y:500)],page:page,active:true).titles.isEmpty)
    }
    func testCoalescedChangesAndPollsHaveOneSerialOriginalRequestPerView() async throws {
        let api = SourceHintsFixtureAPI(), owner = makeOwner(api), id = UUID()
        show(owner,.title(title("first")),id:id)
        owner.record(record(.title(title("latest")),id:id))
        await until { api.requests.count == 1 }
        XCTAssertEqual(api.requests.count,1)
        let rows = try XCTUnwrap(SourceHintFixture.body(api.requests[0])["titles"] as? [[String:Any]])
        XCTAssertEqual(rows.first?["titleId"] as? String,"latest")
        await owner.closeAndDrain()
        XCTAssertEqual(api.maximumInFlight,1)
        let versions = try api.requests.map { try XCTUnwrap(SourceHintFixture.body($0)["version"] as? NSNumber).int64Value }
        XCTAssertEqual(versions,versions.sorted()); XCTAssertEqual(Set(versions).count,versions.count)
        XCTAssertTrue(api.requests.allSatisfy{$0.url!.path.hasSuffix("/test_view")})
    }
    func testHeldOldReplyCannotRepaintANewerVersionOrReviveReleasedDemand() async throws {
        let api = SourceHintsFixtureAPI(), owner = makeOwner(api), id = UUID()
        var pending: CheckedContinuation<Data,Error>?
        var original: URLRequest?
        api.handler = { request in
            if original == nil { original = request; return try await withCheckedThrowingContinuation { pending = $0 } }
            return try SourceHintsFixtureAPI.reply(request)
        }
        show(owner,.title(title("first")),id:id); await until { pending != nil }
        owner.record(record(.title(title("replacement")),id:id))
        pending?.resume(returning:try SourceHintsFixtureAPI.reply(XCTUnwrap(original),hint:SourceHintFixture.raw())); pending = nil
        await until { owner.value(.title(self.title("replacement")),annotation:nil)?.state == "found" }
        XCTAssertNil(owner.value(.title(title("first")),annotation:nil))
        XCTAssertEqual(owner.value(.title(title("replacement")),annotation:nil)?.state,"found")
        await owner.closeAndDrain()
        XCTAssertEqual(api.maximumInFlight,1)
        let final = try XCTUnwrap(SourceHintFixture.body(XCTUnwrap(api.requests.last))["titles"] as? [Any])
        XCTAssertTrue(final.isEmpty)
    }
    func testProfilePINAndConnectionDepartureReleaseOnlyUsableOriginalContext() async throws {
        for change in ["profile","proof","connection"] {
            let api = SourceHintsFixtureAPI(), original = api.context, owner = makeOwner(api)
            var pending: CheckedContinuation<Data,Error>?, request: URLRequest?
            api.handler = { value in request = value; return try await withCheckedThrowingContinuation { pending = $0 } }
            show(owner,.title(title())); await until { pending != nil }
            if change == "profile" { api.context = SourceHintFixture.context("other") }
            else if change == "proof" { api.context = SourceHintFixture.context(proof:"new-proof") }
            else { api.context = SourceActionContext(baseURL:URL(string:"https://other.invalid")!,profileID:"original",clientID:"client",sessionToken:"other") }
            pending?.resume(returning:try SourceHintsFixtureAPI.reply(XCTUnwrap(request))); pending = nil
            await owner.closeAndDrain()
            XCTAssertEqual(api.requests.count,1,"No release may borrow the new frame")
            XCTAssertEqual(api.requests[0].value(forHTTPHeaderField:"X-Profile-Unlock"),"original-proof")
            XCTAssertFalse(owner.current()); XCTAssertNil(owner.value(.title(title()),annotation:try SourceHintFixture.hint()))
            XCTAssertNotEqual(api.context,original)

            let waitingAPI = SourceHintsFixtureAPI()
            var coalesced: CheckedContinuation<Void,Error>?
            let waiting = VisibleSourceHints(context:waitingAPI.context,api:waitingAPI,viewID:"coalesce",coalesce:.milliseconds(250),wait:{ _ in
                try await withCheckedThrowingContinuation { coalesced = $0 }
            })
            show(waiting,.title(title())); await until { coalesced != nil }
            waitingAPI.context = api.context
            coalesced?.resume(); coalesced = nil
            for _ in 0..<100 { await Task.yield() }
            XCTAssertTrue(waitingAPI.requests.isEmpty,"Departure during coalescing must prevent the actual original PUT admission")
            await waiting.closeAndDrain()
        }
        let api = SourceHintsFixtureAPI()
        var originalReply: CheckedContinuation<Data,Error>?, originalRequest: URLRequest?
        api.handler = { request in
            if originalRequest == nil {
                originalRequest = request
                return try await withCheckedThrowingContinuation { originalReply = $0 }
            }
            return try SourceHintsFixtureAPI.reply(request)
        }
        let holder = SourceHintScopeOwner(api:api,currentContext:{ api.context },make:{ context in
            VisibleSourceHints(context:context,api:api,coalesce:.zero,wait:{ duration in
                if duration == .zero { await Task.yield() } else { try await Task.sleep(for:.seconds(3600)) }
            })
        })
        let old = holder.owner
        holder.observe(page,visible:true,allowed:true)
        old.record(record(.title(title())))
        await until { originalReply != nil }
        api.context = SourceHintFixture.context(proof:"after-PIN")
        holder.observe(page,visible:true,allowed:false)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(holder.owner === old,"A blocked PIN page cannot silently acquire a fresh owner")
        holder.observe(page,visible:true,allowed:true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(holder.owner === old,"The actual old admitted PUT must be joined before a new owner is installed")
        originalReply?.resume(returning:try SourceHintsFixtureAPI.reply(XCTUnwrap(originalRequest))); originalReply = nil
        await until { holder.owner !== old }
        XCTAssertFalse(holder.owner === old); XCTAssertNotEqual(holder.owner.viewID,old.viewID)
        XCTAssertEqual(holder.owner.context,api.context)
        holder.owner.record(record(.title(title()))) // Actual environment consumers re-register into this new owner.
        await until { holder.owner.value(.title(self.title()),annotation:nil)?.state == "found" }
        XCTAssertEqual(api.requests.last?.value(forHTTPHeaderField:"X-Profile-Unlock"),"after-PIN")
        XCTAssertFalse(old.current())
        await holder.closeAndDrain()
    }
    func testHiddenCoveredAndUnmountedPageRetiresPollingAndUsesOriginalEmptyRelease() async throws {
        for event in ["hidden","covered","unmounted"] {
            let api = SourceHintsFixtureAPI(), owner = makeOwner(api)
            show(owner,.title(title())); await until { api.requests.count == 1 }
            if event == "hidden" { owner.setPage(page,visible:false) }
            else if event == "covered" { owner.setActive(false) }
            else { await owner.closeAndDrain() }
            await until { api.requests.count == 2 }
            await owner.closeAndDrain()
            XCTAssertEqual(api.requests.count,2)
            let final = try SourceHintFixture.body(api.requests[1])
            XCTAssertEqual((final["titles"] as? [Any])?.count,0)
            XCTAssertEqual(api.requests[1].value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-session")
        }
    }
    func testPendingPollBudgetChangesFromOneSecondToFifteenSeconds() {
        var attempts = 0
        for _ in 0..<15 { XCTAssertEqual(VisibleSourceHints.pollDelay(pending:true,attempts:&attempts),.seconds(1)) }
        XCTAssertEqual(VisibleSourceHints.pollDelay(pending:true,attempts:&attempts),.seconds(15))
        XCTAssertEqual(VisibleSourceHints.pollDelay(pending:false,attempts:&attempts),.seconds(15))
        XCTAssertEqual(attempts,15)
    }
    func testVersionConflictRetiresOwnerAndRateLimitBacksOffWithoutTightReplay() async throws {
        for status in [409,429] {
            let api = SourceHintsFixtureAPI()
            var pauses: [Duration] = []
            let owner = makeOwner(api,wait:{ duration in
                pauses.append(duration)
                if duration == .zero { await Task.yield() } else { try await Task.sleep(for:.seconds(3600)) }
            })
            api.handler = { request in
                let rows = try SourceHintFixture.body(request)["titles"] as? [Any]
                if rows?.isEmpty == true { return try SourceHintsFixtureAPI.reply(request) }
                throw APIError.http(HTTPFailure(status:status,data:Data()))
            }
            show(owner,.title(title())); await until { status == 409 ? !owner.current() : pauses.contains(.seconds(15)) }
            XCTAssertEqual(api.requests.count,1)
            if status == 409 { XCTAssertFalse(owner.current()) } else { XCTAssertTrue(pauses.contains(.seconds(15))) }
            await owner.closeAndDrain()
        }
    }
    func testCancelledOwnerAndLateExpiryCannotTouchReplacementView() async throws {
        let api = SourceHintsFixtureAPI(), first = makeOwner(api)
        var pending: CheckedContinuation<Data,Error>?, held: URLRequest?
        api.handler = { request in
            if held == nil { held = request; return try await withCheckedThrowingContinuation { pending = $0 } }
            return try SourceHintsFixtureAPI.reply(request)
        }
        show(first,.title(title())); await until { pending != nil }
        let closing = Task { await first.closeAndDrain() }
        await Task.yield()
        pending?.resume(returning:try SourceHintsFixtureAPI.reply(XCTUnwrap(held),hint:SourceHintFixture.raw())); pending = nil
        await closing.value
        let secondAPI = SourceHintsFixtureAPI(), second = makeOwner(secondAPI)
        show(second,.title(title())); await until { second.value(.title(self.title()),annotation:nil)?.state == "found" }
        XCTAssertNil(first.value(.title(title()),annotation:try SourceHintFixture.hint()))
        XCTAssertEqual(second.value(.title(title()),annotation:nil)?.state,"found")
        XCTAssertTrue(try SourceHintFixture.hint().presentation(at:SourceHintFixture.now).dimArtwork)
        XCTAssertFalse(try SourceHintFixture.hint().presentation(at:SourceHintFixture.now.addingTimeInterval(400)).dimArtwork)
        await second.closeAndDrain()
    }
    func testEmptyReleaseFailureRemainsUnknownAndNeverClearsThroughAnotherProfile() async throws {
        let api = SourceHintsFixtureAPI(), owner = makeOwner(api)
        api.handler = { request in
            if (try SourceHintFixture.body(request)["titles"] as? [Any])?.isEmpty == true { throw URLError(.networkConnectionLost) }
            return try SourceHintsFixtureAPI.reply(request)
        }
        show(owner,.title(title())); await until { api.requests.count == 1 }
        await owner.closeAndDrain()
        XCTAssertEqual(api.requests.count,2); XCTAssertFalse(owner.current())
        XCTAssertTrue(api.requests.allSatisfy{$0.url!.path.contains("/users/original/")})
        api.context = SourceHintFixture.context("other"); owner.setActive(true)
        await Task.yield(); XCTAssertEqual(api.requests.count,2)
        // No acknowledgement is invented: the old demand's existing server
        // lease expires when this original-frame release could not be confirmed.
    }
}
