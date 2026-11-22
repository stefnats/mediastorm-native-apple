import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class WatchRoomSessionTests: XCTestCase {
    func testLateCreateIsJoinedAndEndedUnderItsOriginalContextAfterClose() async throws {
        let api = WatchRoomTestAPI(), original = api.context, ledger = WatchRoomDepartures()
        let entered = XCTestExpectation(description:"Actual create port entered")
        var pending: CheckedContinuation<Data,Error>?
        api.handler = { request in
            if request.url?.path.hasSuffix("/watch-rooms") == true {
                return try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() }
            }
            return Data()
        }
        let model = WatchRoomsModel(context:original,api:api,departures:ledger)
        model.create(WatchRoomFixture.target(),invitees:[])
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        api.context = PersonalTasteFixture.context("replacement")
        let closing = Task { await model.close() }
        pending?.resume(returning:try WatchRoomFixture.data()); pending = nil
        await closing.value; await model.waitForOperation()
        XCTAssertNil(model.session); XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertEqual(api.requests.map{$0.url!.path},["/base/api/users/original/watch-rooms","/base/api/users/original/watch-rooms/\(WatchRoomFixture.id)/end"])
        XCTAssertEqual(api.requests.last?.value(forHTTPHeaderField:"X-Profile-Unlock"),"original-proof")
    }
    func testLateAcceptCleansOnlyTheRoomFromActualInvitation() async throws {
        let api = WatchRoomTestAPI(), ledger = WatchRoomDepartures(), entered = XCTestExpectation(description:"Accept entered")
        var pending: CheckedContinuation<Data,Error>?
        api.handler = { request in
            if request.url?.path.hasSuffix("/accept") == true { return try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
            return Data()
        }
        let model = WatchRoomsModel(context:api.context,api:api,departures:ledger)
        model.accept(try WatchRoomFixture.invite())
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        let closing = Task { await model.close() }
        pending?.resume(returning:try WatchRoomFixture.data(WatchRoomFixture.fields(joined:false))); pending = nil
        await closing.value
        XCTAssertEqual(api.requests.last?.url?.path,"/base/api/users/original/watch-rooms/\(WatchRoomFixture.id)/leave")
        XCTAssertTrue(ledger.entries.isEmpty); XCTAssertNil(model.session)
    }
    func testUnknownAdmissionHasNoInventedIDNoCleanupAndNoAutomaticSecondCreate() async {
        let api = WatchRoomTestAPI(), ledger = WatchRoomDepartures()
        api.handler = { _ in throw URLError(.timedOut) }
        let model = WatchRoomsModel(context:api.context,api:api,departures:ledger)
        model.create(WatchRoomFixture.target(),invitees:[]); await model.waitForOperation()
        model.create(WatchRoomFixture.target(),invitees:[]); await model.waitForOperation()
        XCTAssertTrue(model.creationUnknown); XCTAssertEqual(api.requests.count,1)
        XCTAssertEqual(ledger.entries.count,1); XCTAssertNil(ledger.entries[0].roomID)
        let cleanup = await ledger.entries[0].depart(retry:true)
        XCTAssertFalse(cleanup); XCTAssertEqual(api.requests.count,1)
        await model.close()
    }
    func testKnownFailedDepartureRemainsOwnedUntilExplicitOriginalRetry() async throws {
        let api = WatchRoomTestAPI(), original = api.context, ledger = WatchRoomDepartures()
        let session = try WatchRoomSession(room:WatchRoomFixture.room(),context:original,api:api,cleanup:.leave,departures:ledger)
        api.handler = { _ in throw URLError(.timedOut) }
        let first = await session.close()
        XCTAssertFalse(first); XCTAssertEqual(ledger.pending(original).count,1)
        api.context = PersonalTasteFixture.context("other"); api.handler = { _ in Data() }
        let retry = await session.retryDeparture()
        XCTAssertTrue(retry); XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertTrue(api.requests.allSatisfy{$0.url?.path == "/base/api/users/original/watch-rooms/\(WatchRoomFixture.id)/leave"})
    }
    func testRevisionConflictReadsWinningStateWithoutRepeatingWrite() async throws {
        let api = WatchRoomTestAPI()
        api.handler = { request in
            if request.httpMethod == "POST" { throw APIError.http(HTTPFailure(status:409,data:Data())) }
            return try WatchRoomFixture.data(WatchRoomFixture.fields(revision:9,position:12))
        }
        let session = try WatchRoomSession(room:WatchRoomFixture.room(),context:api.context,api:api,departures:WatchRoomDepartures())
        let sent = await session.sendState(paused:true,position:20,duration:100)
        XCTAssertFalse(sent); XCTAssertEqual(session.room.revision,9); XCTAssertEqual(session.room.position,12)
        XCTAssertEqual(api.requests.map(\.httpMethod),["POST","GET"])
        _ = await session.close()
    }
    func testJoinQueuedBeforeCloseButNeverAdmittedDoesNotLeaveInvitation() async throws {
        let api = WatchRoomTestAPI(), ledger = WatchRoomDepartures(), entered = XCTestExpectation(description:"Held read entered")
        var pending: CheckedContinuation<Data,Error>?
        api.handler = { request in
            if request.httpMethod == "GET" { return try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
            return Data()
        }
        let session = try WatchRoomSession(room:WatchRoomFixture.room(WatchRoomFixture.fields(joined:false)),context:api.context,api:api,departures:ledger)
        let reading = Task { try? await session.transport.send(WatchRoomWire.request(api.context,method:"GET",room:session.id)) }
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        let joining = Task { await session.join() }
        for _ in 0..<100 where !session.busy { await Task.yield() }
        XCTAssertTrue(session.busy)
        let closing = Task { await session.close() }
        for _ in 0..<10 { await Task.yield() }
        pending?.resume(returning:try WatchRoomFixture.data()); pending = nil
        _ = await reading.value; await joining.value; let closed = await closing.value
        XCTAssertTrue(closed); XCTAssertEqual(api.requests.map(\.httpMethod),["GET"])
        XCTAssertTrue(ledger.entries.isEmpty)
    }
    func testReservationBoundRefusesBeforeAnyRoomMutation() throws {
        let api = WatchRoomTestAPI(), ledger = WatchRoomDepartures()
        let entries = try (0..<64).map { _ in try ledger.reserve(context:api.context,api:api) }
        XCTAssertThrowsError(try ledger.reserve(context:api.context,api:api))
        XCTAssertEqual(ledger.entries.count,64); XCTAssertTrue(api.requests.isEmpty)
        entries.forEach { $0.releaseUnadmitted() }
        XCTAssertTrue(ledger.entries.isEmpty)
    }
    func testExistingCurrentMembershipTransfersOnceAndKeepsActualDeparture() async throws {
        let api = WatchRoomTestAPI(), ledger = WatchRoomDepartures()
        let session = try WatchRoomSession(room:WatchRoomFixture.room(),context:api.context,api:api,departures:ledger)
        try session.assignPlayer(); XCTAssertThrowsError(try session.assignPlayer())
        let closed = await session.close()
        XCTAssertTrue(closed)
        XCTAssertEqual(api.requests.last?.url?.path,"/base/api/users/original/watch-rooms/\(WatchRoomFixture.id)/leave")
        XCTAssertTrue(ledger.entries.isEmpty)
    }
}
