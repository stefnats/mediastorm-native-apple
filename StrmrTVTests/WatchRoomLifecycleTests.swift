import Foundation
import AetherEngine
import XCTest
@testable import StrmrTV

@MainActor
final class WatchRoomLifecycleTests: XCTestCase {
    private func data(expiry: Date) throws -> Data {
        var fields = WatchRoomFixture.fields()
        fields["expiresAt"] = ISO8601DateFormatter().string(from:expiry)
        return try WatchRoomFixture.data(fields)
    }
    private func room(expiry: Date) throws -> WatchRoom {
        let room = try JSONDecoder().decode(WatchRoom.self,from:data(expiry:expiry)); try room.validate(); return room
    }
    private func until(_ predicate: () -> Bool) async {
        for _ in 0..<1000 where !predicate() { await Task.yield() }
    }
    func testConsumedRoomOptionsDisableSDKAutostartBeforeLoadWithoutChangingOriginalHeaders() async throws {
        let api = WatchRoomTestAPI(), now = Date(timeIntervalSince1970:1_800_000_000), expiry = now.addingTimeInterval(60)
        let response = try data(expiry:expiry)
        api.handler = { _ in response }
        let session = try WatchRoomSession(room:room(expiry:expiry),context:api.context,api:api,departures:WatchRoomDepartures(),now:{ now })
        let gate = WatchRoomEngineGate(session:session)
        var base = LoadOptions(); base.autoplay = true; base.audioDelaySeconds = 0.125; base.matchContentEnabled = true
        let headers = ["Authorization":"Bearer synthetic-session","X-Profile-Unlock":"original-proof","X-Client-ID":"client"]
        let options = WatchRoomPlayerViewController.roomLoadOptions(base,headers:headers)
        XCTAssertTrue(base.autoplay,"The room must not change ordinary load defaults")
        XCTAssertFalse(options.autoplay); XCTAssertEqual(options.httpHeaders,headers)
        XCTAssertEqual(options.audioDelaySeconds,base.audioDelaySeconds); XCTAssertEqual(options.matchContentEnabled,base.matchContentEnabled)
        var loaded = false
        try await gate.start(expectedDuration:100,load:{
            XCTAssertFalse(options.autoplay,"The actual controller passes these options before the SDK await")
            XCTAssertTrue(api.requests.isEmpty,"Load precedes the first readiness request")
            loaded = true
        },duration:{ 100 },position:{ 42 },seek:{ _ in },pause:{})
        XCTAssertTrue(loaded)
        XCTAssertEqual(api.requests.map{$0.url!.lastPathComponent},["ready"])
    }
    func testHeldRoomGETCannotDelayExpiryPauseAndOriginalJoinedDeparture() async throws {
        let api = WatchRoomTestAPI(), original = api.context, ledger = WatchRoomDepartures()
        var now = Date(timeIntervalSince1970:1_800_000_000)
        let expiry = now.addingTimeInterval(2), response = try data(expiry:expiry)
        let session = try WatchRoomSession(room:room(expiry:expiry),context:original,api:api,cleanup:.leave,departures:ledger,now:{ now })
        let gate = WatchRoomEngineGate(session:session)
        api.handler = { _ in response }
        try await gate.start(expectedDuration:100,load:{},duration:{ 100 },position:{ 42 },seek:{ _ in },pause:{})
        let getEntered = XCTestExpectation(description:"Actual room GET entered")
        var getReply: CheckedContinuation<Data,Error>?
        api.handler = { request in
            if request.httpMethod == "GET" { return try await withCheckedThrowingContinuation { getReply = $0; getEntered.fulfill() } }
            return Data()
        }
        let reading = Task { await session.refresh() }
        let getWait = await XCTWaiter.fulfillment(of:[getEntered],timeout:2); XCTAssertEqual(getWait,.completed)
        let tickEntered = XCTestExpectation(description:"Independent lifecycle wait entered")
        var tick: CheckedContinuation<Void,Error>?
        var pauses = 0, completed = false
        var closing: Task<Void,Never>?
        let owner = WatchRoomLifecycle(session:session,expired:{
            pauses += 1; gate.close()
            closing = Task { _ = await session.close(); completed = true }
        },wait:{ try await withCheckedThrowingContinuation { tick = $0; tickEntered.fulfill() } })
        owner.start()
        let tickWait = await XCTWaiter.fulfillment(of:[tickEntered],timeout:2); XCTAssertEqual(tickWait,.completed)
        now = expiry
        tick?.resume(); tick = nil
        await until { session.closed }
        XCTAssertFalse(session.current()); XCTAssertEqual(pauses,1)
        XCTAssertFalse(completed,"The original admitted GET must still be joined before departure")
        XCTAssertFalse(api.requests.contains{$0.url!.path.hasSuffix("/leave")})
        XCTAssertThrowsError(try gate.check())
        getReply?.resume(returning:response); getReply = nil
        await reading.value; await closing?.value; await owner.stop()?.value
        XCTAssertTrue(completed); XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertEqual(api.requests.last?.url?.path,"/base/api/users/original/watch-rooms/\(WatchRoomFixture.id)/leave")
        XCTAssertEqual(api.requests.last?.value(forHTTPHeaderField:"X-Profile-Unlock"),"original-proof")
        XCTAssertEqual(api.requests.filter{$0.url!.path.hasSuffix("/leave")}.count,1)
    }
    func testStoppedLifecycleIgnoresLateWaitAndCannotTouchReplacementPlayer() async throws {
        for closingSession in [false,true] {
            let api = WatchRoomTestAPI()
            var now = Date(timeIntervalSince1970:1_800_000_000)
            let expiry = now.addingTimeInterval(1)
            let session = try WatchRoomSession(room:room(expiry:expiry),context:api.context,api:api,departures:WatchRoomDepartures(),now:{ now })
            let entered = XCTestExpectation(description:"Old lifecycle held")
            var tick: CheckedContinuation<Void,Error>?, oldPauses = 0, replacementPauses = 0
            let owner = WatchRoomLifecycle(session:session,expired:{ oldPauses += 1 },wait:{
                try await withCheckedThrowingContinuation { tick = $0; entered.fulfill() }
            })
            owner.start()
            let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
            let stopped = owner.stop()
            if closingSession { _ = await session.close() }
            let replacement = try WatchRoomSession(room:room(expiry:expiry.addingTimeInterval(100)),context:api.context,api:api,departures:WatchRoomDepartures(),now:{ now })
            let replacementGate = WatchRoomEngineGate(session:replacement)
            var nextTick: CheckedContinuation<Void,Error>?
            let nextOwner = WatchRoomLifecycle(session:replacement,expired:{ replacementPauses += 1 },wait:{
                try await withCheckedThrowingContinuation { nextTick = $0 }
            })
            nextOwner.start(); await until { nextTick != nil }
            now = expiry.addingTimeInterval(1)
            tick?.resume(); tick = nil; await stopped?.value
            XCTAssertEqual(oldPauses,0); XCTAssertEqual(replacementPauses,0)
            XCTAssertTrue(replacement.current()); XCTAssertNoThrow(try replacementGate.check())
            let nextStopped = nextOwner.stop()
            nextTick?.resume(); nextTick = nil; await nextStopped?.value
            XCTAssertEqual(replacementPauses,0)
            XCTAssertTrue(api.requests.isEmpty)
        }
    }
    func testFutureSessionRemainsCurrentAcrossIndependentTicksAndExpiryIsExact() async throws {
        let api = WatchRoomTestAPI()
        var now = Date(timeIntervalSince1970:1_800_000_000)
        let expiry = now.addingTimeInterval(60)
        let session = try WatchRoomSession(room:room(expiry:expiry),context:api.context,api:api,departures:WatchRoomDepartures(),now:{ now })
        var ticks = 0, pauses = 0
        var pending: CheckedContinuation<Void,Error>?
        let owner = WatchRoomLifecycle(session:session,expired:{ pauses += 1 },wait:{
            ticks += 1
            if ticks > 3 { try await withCheckedThrowingContinuation { pending = $0 } }
            else { await Task.yield() }
        })
        owner.start(); await until { ticks == 4 }
        XCTAssertEqual(ticks,4); XCTAssertEqual(pauses,0); XCTAssertTrue(session.current()); XCTAssertTrue(api.requests.isEmpty)
        now = expiry.addingTimeInterval(-0.001); XCTAssertTrue(session.current())
        now = expiry; XCTAssertFalse(session.current())
        pending?.resume(); pending = nil
        await until { pauses == 1 }; await owner.stop()?.value
        XCTAssertEqual(pauses,1)
        owner.start(); await Task.yield(); XCTAssertEqual(pauses,1)
    }
}
