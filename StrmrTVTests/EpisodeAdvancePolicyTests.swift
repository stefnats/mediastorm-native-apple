import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class EpisodeAdvancePolicyTests: XCTestCase {
    func ended(_ enabled: Bool? = true) -> EpisodeAdvancePolicy {
        var policy = EpisodeAdvancePolicy(hasTarget: true); policy.autoplay = enabled
        XCTAssertTrue(policy.ended(position: 100, duration: 100, failed: false)); return policy
    }
    func credits(_ enabled: Bool? = true, skip: Bool = true) -> EpisodeAdvancePolicy {
        var policy = EpisodeAdvancePolicy(hasTarget: true); policy.autoplay = enabled; policy.skipCredits = skip
        policy.observe(credits: true, playing: true, position: 91, duration: 100, failed: false); return policy
    }
    func testNaturalEndAutoplayCreditsSkipMatrix() {
        for enabled in [false, true] { for skip in [false, true] {
            var policy = ended(enabled); policy.skipCredits = skip
            XCTAssertFalse(policy.tick(now: .zero)); XCTAssertEqual(policy.seconds, enabled ? 5 : nil)
            XCTAssertEqual(policy.tick(now: .seconds(5)), enabled)
        } }
    }
    func testCreditsAdvanceRequiresBothIndependentFlags() {
        for enabled in [false, true] { for skip in [false, true] {
            var policy = credits(enabled, skip: skip)
            XCTAssertFalse(policy.tick(now: .zero)); XCTAssertEqual(policy.seconds, enabled && skip ? 7 : nil)
            XCTAssertEqual(policy.tick(now: .seconds(7)), enabled && skip)
        } }
    }
    func testNaturalEndUsesFiveSecondVisibleCountdown() {
        var policy = ended(); XCTAssertTrue(policy.visible)
        XCTAssertFalse(policy.tick(now: .zero)); XCTAssertEqual(policy.seconds, 5)
        XCTAssertFalse(policy.tick(now: .milliseconds(4999))); XCTAssertEqual(policy.seconds, 1)
        XCTAssertTrue(policy.tick(now: .seconds(5))); XCTAssertFalse(policy.visible)
    }
    func testCreditsUsesSevenSecondVisibleCountdown() {
        var policy = credits(); XCTAssertFalse(policy.visible)
        XCTAssertFalse(policy.tick(now: .zero)); XCTAssertTrue(policy.visible); XCTAssertEqual(policy.seconds, 7)
        XCTAssertFalse(policy.tick(now: .seconds(6))); XCTAssertEqual(policy.seconds, 1)
        XCTAssertTrue(policy.tick(now: .seconds(7)))
    }
    func testPauseHoldsRemainingCountdown() {
        var policy = ended(); _ = policy.tick(now: .zero); _ = policy.tick(now: .seconds(2))
        policy.togglePause(); XCTAssertFalse(policy.tick(now: .seconds(100)))
        XCTAssertEqual(policy.seconds, 3); XCTAssertTrue(policy.countdownPaused)
        var media = credits(); _ = media.tick(now: .zero); _ = media.tick(now: .seconds(2))
        media.observe(credits: true, playing: false, position: 93, duration: 100, failed: false)
        XCTAssertFalse(media.tick(now: .seconds(100))); XCTAssertEqual(media.seconds, 5)
        media.observe(credits: true, playing: true, position: 93, duration: 100, failed: false)
        XCTAssertFalse(media.tick(now: .seconds(200))); XCTAssertEqual(media.seconds, 5)
        XCTAssertTrue(media.tick(now: .seconds(205)))
    }
    func testResumeContinuesRemainingMonotonicDuration() {
        var policy = ended(); _ = policy.tick(now: .zero); _ = policy.tick(now: .seconds(2))
        policy.togglePause(); _ = policy.tick(now: .seconds(50)); policy.togglePause()
        XCTAssertFalse(policy.tick(now: .seconds(100))); XCTAssertEqual(policy.seconds, 3)
        XCTAssertFalse(policy.tick(now: .seconds(102))); XCTAssertTrue(policy.tick(now: .seconds(103)))
    }
    func testCancelAtCreditsBlocksLaterNaturalEndAutostart() {
        var policy = credits(); _ = policy.tick(now: .zero); policy.cancel()
        XCTAssertTrue(policy.ended(position: 100, duration: 100, failed: false))
        XCTAssertFalse(policy.tick(now: .seconds(50))); XCTAssertNil(policy.seconds); XCTAssertTrue(policy.visible)
    }
    func testRepeatedEndNeverRestartsCancelledCountdown() {
        var policy = ended(); _ = policy.tick(now: .zero); policy.cancel()
        for second in [5, 50, 500] {
            XCTAssertTrue(policy.ended(position: 100, duration: 100, failed: false))
            XCTAssertFalse(policy.tick(now: .seconds(second))); XCTAssertNil(policy.seconds)
        }
    }
    func testManualStartAndTimerShareOneClaim() {
        var manual = ended(); _ = manual.tick(now: .zero)
        XCTAssertTrue(manual.claim()); XCTAssertFalse(manual.tick(now: .seconds(10))); XCTAssertFalse(manual.claim())
        var timer = ended(); _ = timer.tick(now: .zero)
        XCTAssertTrue(timer.tick(now: .seconds(5))); XCTAssertFalse(timer.claim()); XCTAssertFalse(timer.tick(now: .seconds(50)))
    }
    func testEarlyEofFailureAndUnknownDurationDoNotAdvance() {
        for (position, duration, failed) in [(50.0, 100.0, false), (100, 100, true), (0, 0, false), (Double.nan, 100, false), (100, Double.infinity, false)] {
            var policy = EpisodeAdvancePolicy(hasTarget: true); policy.autoplay = true
            XCTAssertFalse(policy.ended(position: position, duration: duration, failed: failed))
            XCTAssertFalse(policy.tick(now: .seconds(20))); XCTAssertFalse(policy.visible)
        }
    }
    func testLeavingCreditsDisarmsEarlyAutomaticTransition() {
        var policy = credits(); _ = policy.tick(now: .zero)
        policy.observe(credits: false, playing: true, position: 30, duration: 100, failed: false)
        XCTAssertFalse(policy.tick(now: .seconds(20))); XCTAssertNil(policy.seconds)
        policy.observe(credits: true, playing: true, position: 91, duration: 100, failed: false)
        XCTAssertFalse(policy.tick(now: .seconds(40))); XCTAssertNil(policy.seconds)
        XCTAssertTrue(policy.claim())
    }
    func testLateSettingsDoNotUndoCancelOrStartDuplicate() {
        var policy = ended(nil); policy.cancel(); policy.autoplay = true
        XCTAssertFalse(policy.tick(now: .seconds(10))); XCTAssertNil(policy.seconds)
        XCTAssertTrue(policy.claim()); policy.autoplay = false; policy.autoplay = true
        XCTAssertFalse(policy.tick(now: .seconds(20))); XCTAssertFalse(policy.claim())
    }
    func testUnknownSettingAllowsManualTargetOnly() {
        var policy = ended(nil); XCTAssertTrue(policy.visible)
        XCTAssertFalse(policy.tick(now: .zero)); XCTAssertFalse(policy.tick(now: .seconds(100))); XCTAssertTrue(policy.claim())
    }
    func testAvailableCrossSeasonTargetIsPreserved() throws {
        let title = DetailsTarget(try PostPlayFixture.title(series: true))
        let current = PlaybackRequest.EpisodeInfo(season: 1, episode: 10, absolute: nil, name: "Finale", itemID: "stored-final")
        let next = PlaybackRequest.EpisodeInfo(season: 2, episode: 1, absolute: nil, name: "New season", itemID: "stored-next")
        let request = PlaybackRequest(title: title, episode: current, start: nil, following: [next])
        XCTAssertEqual(request.nextEpisode?.episode?.season, 2); XCTAssertEqual(request.nextEpisode?.progressItemID, "stored-next")
        let future = try PostPlayFixture.request(series: true, episodes: [PostPlayFixture.episode(), PostPlayFixture.episode(2, future: true)])
        XCTAssertNil(future.nextEpisode)
    }
    func testNoTargetNeverClaimsAnEpisode() {
        var policy = EpisodeAdvancePolicy(hasTarget: false); policy.autoplay = true; policy.skipCredits = true
        policy.observe(credits: true, playing: true, position: 99, duration: 100, failed: false)
        XCTAssertFalse(policy.ended(position: 100, duration: 100, failed: false)); XCTAssertFalse(policy.tick(now: .seconds(100)))
        XCTAssertFalse(policy.visible); XCTAssertFalse(policy.claim())
    }
    func testClosedPolicyNeverAdoptsLateTickOrAction() {
        var policy = ended(); _ = policy.tick(now: .zero); policy.close()
        policy.autoplay = true; policy.skipCredits = true
        XCTAssertFalse(policy.tick(now: .seconds(10))); XCTAssertFalse(policy.claim())
        XCTAssertFalse(policy.ended(position: 100, duration: 100, failed: false)); XCTAssertFalse(policy.visible)
    }
}
