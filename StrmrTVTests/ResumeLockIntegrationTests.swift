import AetherEngine
import UIKit
import XCTest
@testable import StrmrTV

@MainActor
final class ResumeLockIntegrationTests: XCTestCase {
    func testActualProductionControllerClassifierIncludesEveryProtectedHost() {
        XCTAssertTrue(AppSession.isProtectedPlaybackType(PlayerViewController.self))
        XCTAssertTrue(AppSession.isProtectedPlaybackType(LivePlayerViewController.self))
        XCTAssertTrue(AppSession.isProtectedPlaybackType(RecordingPlayerViewController.self))
        XCTAssertTrue(AppSession.isProtectedPlaybackType(MultiscreenHostController.self))
        XCTAssertFalse(AppSession.isProtectedPlaybackType(UIViewController.self))
    }

    func testActualForegroundPolicyRetainsHealthyEngineButNotLostVideoSession() {
        XCTAssertTrue(PlayerViewController.retainsForegroundPlayback(.playing, needsVideoRestore: false))
        XCTAssertTrue(PlayerViewController.retainsForegroundPlayback(.paused, needsVideoRestore: false))
        XCTAssertFalse(PlayerViewController.retainsForegroundPlayback(.playing, needsVideoRestore: true))
        XCTAssertFalse(PlayerViewController.retainsForegroundPlayback(.paused, needsVideoRestore: true))
        XCTAssertFalse(PlayerViewController.retainsForegroundPlayback(.ended, needsVideoRestore: false))
        XCTAssertFalse(PlayerViewController.retainsForegroundPlayback(.error("synthetic connection failure"), needsVideoRestore: false))
    }

    func testPlayerToPlayerTransitionRetainsTheOriginalExitDemand() {
        var time = Duration.zero
        let gate = DeferredResumeGate(now: { time })
        let context = SourceActionContext(baseURL: URL(string: "https://synthetic.invalid")!,
            profileID: "protected", clientID: "actual-client", sessionToken: "original")
        let owner = ResumePINOwner(context: context, activation: UUID(), session: "original")
        gate.backgrounded(); time = .seconds(300)
        XCTAssertEqual(gate.foreground(owner: owner, requiresPIN: true, player: true,
            automatic: false, showPicker: true, profileCount: 2), .deferred)
        // Production presentation and resolving work both count as playback.
        XCTAssertEqual(gate.browsing(owner: owner, requiresPIN: true, player: true), .deferred)
        XCTAssertTrue(gate.blocked)
        guard case let .pin(ticket) = gate.browsing(owner: owner, requiresPIN: true, player: false) else {
            return XCTFail("Actual browsing did not consume the deferred demand")
        }
        XCTAssertTrue(gate.current(ticket, owner: owner))
        XCTAssertTrue(gate.complete(ticket, owner: owner))
    }
}
