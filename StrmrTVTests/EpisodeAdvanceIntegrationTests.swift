import Foundation
import XCTest
@testable import StrmrTV

/// Exercises the production controller and the same transition owner consumed by
/// PlaybackCoordinator. UIKit dismissal, AetherEngine and real HTTP remain unexecuted.
@MainActor
final class EpisodeAdvanceIntegrationTests: XCTestCase {
    func controller(_ api: EpisodeFixtureAPI, time: @escaping () -> Duration,
                    active: @escaping () -> Bool = { true }, advance: @escaping (PlaybackRequest) -> Void) throws -> EpisodeAdvanceController {
        EpisodeAdvanceController(next: try EpisodeFixture.next(), context: api.context, api: api,
            now: time, active: active, advance: advance)
    }
    func testActualControllerConsumesNaturalEndAndOriginalSetting() async throws {
        let api = EpisodeFixtureAPI(); var time = Duration.zero, starts: [String] = []
        let actor = try controller(api, time: { time }, advance: { starts.append($0.prequeueKey) }); defer { actor.close() }
        actor.start(scheduleTimer: false); await EpisodeFixture.settle { !actor.loadingSettings }
        XCTAssertEqual(api.calls, ["read:original"])
        XCTAssertTrue(actor.naturalEnd(position: 100, duration: 100, failed: false)); XCTAssertEqual(actor.seconds, 5)
        time = .seconds(5); actor.tick(); actor.tick(); XCTAssertEqual(starts, [try EpisodeFixture.next().prequeueKey])
    }
    func testActualControllerCombinesCreditsAndConfirmedProfileFlags() async throws {
        for autoplay in [false, true] { for skip in [false, true] {
            let api = EpisodeFixtureAPI(); api.value = .init(enabled: autoplay, skipCredits: skip, detectCredits: false)
            var time = Duration.zero, starts = 0
            let actor = try controller(api, time: { time }, advance: { _ in starts += 1 })
            actor.start(scheduleTimer: false); await EpisodeFixture.settle { !actor.loadingSettings }
            actor.observe(credits: true, playing: true, position: 91, duration: 100, failed: false)
            XCTAssertEqual(actor.seconds, autoplay && skip ? 7 : nil)
            time = .seconds(7); actor.tick(); XCTAssertEqual(starts, autoplay && skip ? 1 : 0); actor.close()
        } }
    }
    func testControllerPauseCancelAndManualActionsReachSamePolicy() async throws {
        let api = EpisodeFixtureAPI(); var time = Duration.zero, starts = 0
        let actor = try controller(api, time: { time }, advance: { _ in starts += 1 }); defer { actor.close() }
        actor.start(scheduleTimer: false); await EpisodeFixture.settle { !actor.loadingSettings }
        XCTAssertTrue(actor.naturalEnd(position: 100, duration: 100, failed: false))
        time = .seconds(2); actor.tick(); actor.pauseCountdown(); time = .seconds(50); actor.tick()
        XCTAssertEqual(actor.seconds, 3); actor.pauseCountdown(); actor.cancelCountdown()
        XCTAssertTrue(actor.naturalEnd(position: 100, duration: 100, failed: false)); time = .seconds(100); actor.tick()
        XCTAssertEqual(starts, 0); actor.startNow(); actor.startNow(); actor.tick(); XCTAssertEqual(starts, 1)
    }
    func testOriginalProfileSwitchPreventsLateSettingsAndAdvance() async throws {
        let api = EpisodeFixtureAPI(); api.holdRead = true; var starts = 0
        let actor = try controller(api, time: { .seconds(50) }, advance: { _ in starts += 1 }); defer { actor.close() }
        actor.start(scheduleTimer: false); await EpisodeFixture.settle { api.read != nil }
        api.context = PostPlayFixture.context("replacement"); api.reply()
        await EpisodeFixture.settle { !actor.loadingSettings }
        XCTAssertFalse(actor.naturalEnd(position: 100, duration: 100, failed: false)); actor.startNow(); actor.tick()
        XCTAssertFalse(actor.current); XCTAssertFalse(actor.visible); XCTAssertEqual(starts, 0)
    }
    func testConfirmedLocalRevisionBeatsOlderQueuedPlayerRead() async throws {
        let api = EpisodeFixtureAPI(); api.holdRead = true; var time = Duration.zero, starts = 0
        let actor = try controller(api, time: { time }, advance: { _ in starts += 1 }); defer { actor.close() }
        actor.start(scheduleTimer: false); await EpisodeFixture.settle { api.read != nil }
        EpisodeAutoplayChanges.saved(false, context: api.context); api.reply(); await EpisodeFixture.settle { !actor.loadingSettings }
        XCTAssertTrue(actor.naturalEnd(position: 100, duration: 100, failed: false)); time = .seconds(50); actor.tick()
        XCTAssertNil(actor.seconds); XCTAssertEqual(starts, 0)
        EpisodeAutoplayChanges.saved(true, context: api.context); XCTAssertEqual(actor.seconds, 5)
        time = .seconds(55); actor.tick(); XCTAssertEqual(starts, 1)
    }
    func testCloseCancelsOwnedTimerReadAndPublication() async throws {
        let api = EpisodeFixtureAPI(); api.holdRead = true; var starts = 0
        let actor = try controller(api, time: { .seconds(100) }, advance: { _ in starts += 1 })
        actor.start(scheduleTimer: false); await EpisodeFixture.settle { api.read != nil }; actor.close()
        api.reply(); await EpisodeFixture.settle { api.readReturns > 0 }; await Task.yield()
        EpisodeAutoplayChanges.saved(true, context: api.context); actor.tick(); actor.startNow()
        XCTAssertFalse(actor.current); XCTAssertFalse(actor.visible); XCTAssertEqual(starts, 0)
        // A background/modal interval does not consume countdown time.
        let secondAPI = EpisodeFixtureAPI(); var time = Duration.zero, active = true
        let second = try controller(secondAPI, time: { time }, active: { active }, advance: { _ in starts += 1 }); defer { second.close() }
        second.start(scheduleTimer: false); await EpisodeFixture.settle { !second.loadingSettings }
        _ = second.naturalEnd(position: 100, duration: 100, failed: false)
        active = false; time = .seconds(100); second.tick(); active = true; second.tick(); XCTAssertEqual(second.seconds, 5)
        second.suspend(true); time = .seconds(200); second.tick(); second.suspend(false); second.tick(); XCTAssertEqual(second.seconds, 5)
    }
    func testKnownDenialStopsAutomaticAndManualContinuation() async throws {
        let api = EpisodeFixtureAPI(); api.readError = EpisodeFixture.denial(); var starts = 0
        let actor = try controller(api, time: { .seconds(100) }, advance: { _ in starts += 1 }); defer { actor.close() }
        actor.start(scheduleTimer: false); await EpisodeFixture.settle { !actor.loadingSettings }
        actor.startNow(); actor.tick(); XCTAssertFalse(actor.current); XCTAssertEqual(starts, 0)
        let owner = EpisodeTransitionOwnership(current: api.isCurrent)
        let ticket = try XCTUnwrap(owner.prepare(EpisodeFixture.next(), context: api.context)), resolve = UUID()
        XCTAssertTrue(owner.bind(ticket, resolve: resolve))
        let failure = try XCTUnwrap(owner.failed(ticket, resolve: resolve, error: EpisodeFixture.denial()))
        XCTAssertTrue(failure.denied); XCTAssertNil(owner.retry(failure))
    }
    func testTransitionRetainsExactFailedNextRequest() throws {
        let api = EpisodeFixtureAPI(), owner = EpisodeTransitionOwnership(current: { _ in true })
        let request = try EpisodeFixture.next(), ticket = try XCTUnwrap(owner.prepare(request, context: api.context)), resolve = UUID()
        XCTAssertTrue(owner.bind(ticket, resolve: resolve))
        let failure = try XCTUnwrap(owner.failed(ticket, resolve: resolve, error: URLError(.cannotFindHost)))
        XCTAssertEqual(failure.request.prequeueKey, request.prequeueKey)
        XCTAssertEqual(failure.request.progressItemID, "stored-original-2"); XCTAssertEqual(failure.request.following.first?.itemID, "stored-original-3")
        XCTAssertEqual(failure.context, api.context)
    }
    func testRetryIsExplicitSameTargetAndNeverSkipsFollowing() throws {
        let api = EpisodeFixtureAPI(), owner = EpisodeTransitionOwnership(current: { _ in true })
        let ticket = try XCTUnwrap(owner.prepare(EpisodeFixture.next(), context: api.context)), resolve = UUID()
        _ = owner.bind(ticket, resolve: resolve)
        let failure = try XCTUnwrap(owner.failed(ticket, resolve: resolve, error: URLError(.cannotConnectToHost)))
        XCTAssertEqual(owner.ticket?.id, ticket.id)
        let retry = try XCTUnwrap(owner.retry(failure))
        XCTAssertNotEqual(retry.id, ticket.id); XCTAssertEqual(retry.request.prequeueKey, ticket.request.prequeueKey)
        XCTAssertEqual(retry.request.episode?.episode, 2); XCTAssertNil(owner.retry(failure))
    }
    func testReplacementOperationIgnoresOldResolveFailure() throws {
        let api = EpisodeFixtureAPI(), owner = EpisodeTransitionOwnership(current: { _ in true })
        let old = try XCTUnwrap(owner.prepare(EpisodeFixture.next(), context: api.context)), oldResolve = UUID()
        _ = owner.bind(old, resolve: oldResolve)
        let replacement = try XCTUnwrap(owner.prepare(EpisodeFixture.next(), context: api.context)), newResolve = UUID()
        _ = owner.bind(replacement, resolve: newResolve)
        XCTAssertNil(owner.failed(old, resolve: oldResolve, error: URLError(.cannotFindHost)))
        owner.succeeded(old, resolve: oldResolve); XCTAssertTrue(owner.current(replacement, resolve: newResolve))
        owner.retire(); XCTAssertFalse(owner.current(replacement)); XCTAssertNil(owner.failed(replacement, resolve: newResolve, error: URLError(.cannotFindHost)))
    }
    func testCancelledResolveDoesNotCreateRetry() throws {
        let api = EpisodeFixtureAPI(), owner = EpisodeTransitionOwnership(current: { _ in true })
        let ticket = try XCTUnwrap(owner.prepare(EpisodeFixture.next(), context: api.context)), resolve = UUID()
        _ = owner.bind(ticket, resolve: resolve)
        XCTAssertNil(owner.failed(ticket, resolve: resolve, error: CancellationError()))
        XCTAssertNil(owner.failed(ticket, resolve: resolve, error: URLError(.cancelled)))
        XCTAssertNil(owner.failure); owner.retire(); XCTAssertFalse(owner.current(ticket))
    }
    func testCurrentRetryDetailsAndCloseKeepOriginalOwner() throws {
        let api = EpisodeFixtureAPI(), owner = EpisodeTransitionOwnership(current: { _ in true })
        let old = try XCTUnwrap(owner.prepare(EpisodeFixture.next(), context: api.context)), oldResolve = UUID()
        _ = owner.bind(old, resolve: oldResolve)
        let oldFailure = try XCTUnwrap(owner.failed(old, resolve: oldResolve, error: URLError(.cannotFindHost)))
        let replacement = try XCTUnwrap(owner.prepare(EpisodeFixture.next(), context: api.context)), newResolve = UUID()
        _ = owner.bind(replacement, resolve: newResolve)
        owner.dismiss(oldFailure); XCTAssertTrue(owner.current(replacement, resolve: newResolve))
        let failure = try XCTUnwrap(owner.failed(replacement, resolve: newResolve, error: URLError(.cannotFindHost)))
        XCTAssertEqual(failure.request.title.titleID, replacement.request.title.titleID); XCTAssertTrue(owner.canRetry(failure))
        owner.dismiss(failure); XCTAssertNil(owner.ticket)
        let strict = EpisodeTransitionOwnership(current: api.isCurrent)
        let changed = try XCTUnwrap(strict.prepare(EpisodeFixture.next(), context: api.context)), changedResolve = UUID()
        _ = strict.bind(changed, resolve: changedResolve)
        let changedFailure = try XCTUnwrap(strict.failed(changed, resolve: changedResolve, error: URLError(.cannotFindHost)))
        api.context = PostPlayFixture.context("replacement"); XCTAssertFalse(strict.canRetry(changedFailure)); XCTAssertNil(strict.retry(changedFailure))
    }
}
