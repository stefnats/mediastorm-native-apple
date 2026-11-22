import XCTest
@testable import StrmrTV

@MainActor
final class DeferredResumeGateTests: XCTestCase {
    private var time: Duration = .zero
    private let activation = UUID()
    private func owner(profile: String = "original", session: String = "session", server: String = "https://server.invalid") -> ResumePINOwner {
        ResumePINOwner(context: SourceActionContext(baseURL: URL(string: server)!, profileID: profile,
            clientID: "client", sessionToken: session), activation: activation, session: session)
    }
    private func foreground(_ gate: DeferredResumeGate, owner: ResumePINOwner, player: Bool = false,
                            automatic: Bool = false, pin: Bool = true, picker: Bool = false) -> DeferredResumeGate.Action {
        gate.foreground(owner: owner, requiresPIN: pin, player: player, automatic: automatic,
                        showPicker: picker, profileCount: 2)
    }

    func testContinuousFiveMinuteBoundaryAndAutomaticSelection() {
        let gate = DeferredResumeGate(now: { self.time })
        gate.backgrounded()
        time = .milliseconds(299999)
        XCTAssertEqual(foreground(gate, owner: owner(), automatic: true), .none)
        gate.backgrounded()
        time += .seconds(300)
        guard case let .pin(ticket) = foreground(gate, owner: owner(), automatic: true) else {
            return XCTFail("Automatic profile selection skipped the five-minute PIN")
        }
        XCTAssertTrue(gate.blocked)
        XCTAssertTrue(gate.complete(ticket, owner: owner()))
        XCTAssertFalse(gate.blocked)
    }

    func testDuplicateBackgroundNotificationsCannotRenewOriginalAbsence() {
        let gate = DeferredResumeGate(now: { self.time })
        gate.backgrounded()
        time = .seconds(299)
        gate.backgrounded()
        time = .seconds(300)
        XCTAssertEqual(foreground(gate, owner: owner(), player: true), .deferred)
        XCTAssertTrue(gate.blocked)
    }

    func testActiveOrPausedPlayerDefersUntilActualBrowsingAndDoesNotConsumeDemand() {
        let gate = DeferredResumeGate(now: { self.time })
        gate.backgrounded()
        time = .seconds(300)
        XCTAssertEqual(foreground(gate, owner: owner(), player: true), .deferred)
        XCTAssertEqual(gate.browsing(owner: owner(), requiresPIN: true, player: true), .deferred)
        XCTAssertTrue(gate.blocked)
        guard case let .pin(ticket) = gate.browsing(owner: owner(), requiresPIN: true, player: false) else {
            return XCTFail("Leaving playback lost its PIN obligation")
        }
        XCTAssertEqual(gate.browsing(owner: owner(), requiresPIN: true, player: false), .none)
        gate.release(ticket)
        XCTAssertTrue(gate.blocked, "Cancel must not expose protected browsing")
        guard case let .pin(retry) = gate.browsing(owner: owner(), requiresPIN: true, player: false) else {
            return XCTFail("A cancelled prompt prevented an explicit retry")
        }
        XCTAssertEqual(retry, ticket)
        XCTAssertTrue(gate.complete(retry, owner: owner()))
    }

    func testProfileSessionAndServerChangesRejectOldPINCompletion() {
        for changed in [owner(profile: "other"), owner(session: "new-session"), owner(server: "https://other.invalid")] {
            let gate = DeferredResumeGate(now: { self.time })
            gate.backgrounded()
            time += .seconds(300)
            guard case let .pin(old) = foreground(gate, owner: owner()) else { return XCTFail("No original PIN") }
            guard case let .pin(next) = gate.browsing(owner: changed, requiresPIN: true, player: false) else {
                return XCTFail("Changed authority silently adopted original obligation")
            }
            XCTAssertNotEqual(old.id, next.id)
            XCTAssertFalse(gate.complete(old, owner: changed))
            XCTAssertTrue(gate.blocked)
            XCTAssertTrue(gate.complete(next, owner: changed))
        }
    }

    func testExplicitProfileActivationInvalidatesOldTicket() {
        let gate = DeferredResumeGate(now: { self.time })
        gate.backgrounded(); time = .seconds(300)
        guard case let .pin(old) = foreground(gate, owner: owner()) else { return XCTFail("No PIN") }
        gate.profileActivated()
        XCTAssertFalse(gate.blocked)
        XCTAssertFalse(gate.complete(old, owner: owner()))
        XCTAssertEqual(gate.browsing(owner: owner(), requiresPIN: true, player: false), .none)
    }

    func testShortPickerAndUnprotectedProfilesRetainTheirExistingPolicies() {
        let gate = DeferredResumeGate(now: { self.time })
        gate.backgrounded(); time = .seconds(3)
        XCTAssertEqual(foreground(gate, owner: owner(), picker: true), .picker)
        XCTAssertFalse(gate.blocked)
        gate.backgrounded(); time += .seconds(3)
        XCTAssertEqual(foreground(gate, owner: owner(), automatic: true, picker: true), .none)
        gate.backgrounded(); time += .seconds(300)
        XCTAssertEqual(foreground(gate, owner: owner(), automatic: true, pin: false), .none)
        XCTAssertFalse(gate.blocked)
    }

    func testOwnUnlockTokenChangeDoesNotReplaceTheActualViewer() {
        let gate = DeferredResumeGate(now: { self.time })
        let original = owner()
        let acknowledged = ResumePINOwner(context: SourceActionContext(baseURL: URL(string: "https://server.invalid")!,
            profileID: "original", clientID: "client", sessionToken: "session", unlock: "new-own-pin-unlock"),
            activation: activation, session: "session")
        gate.backgrounded(); time = .seconds(300)
        guard case let .pin(ticket) = foreground(gate, owner: original) else { return XCTFail("No PIN") }
        XCTAssertTrue(gate.complete(ticket, owner: acknowledged))
    }
}
