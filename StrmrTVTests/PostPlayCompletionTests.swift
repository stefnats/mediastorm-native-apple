import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class PostPlayProgressFixture: PlayerProgressAPI {
    var context = PostPlayFixture.context()
    var calls: [[String: Any]] = []
    var viewers: [SourceActionContext] = []
    var pending: [Int: CheckedContinuation<ProgressReply?, Never>] = [:]
    func sourceContext() -> SourceActionContext { context }
    func reportOriginalProgress(_ body: [String: Any], context: SourceActionContext) async -> ProgressReply? {
        let index = calls.count; calls.append(body); viewers.append(context)
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, item: String? = "canonical-stored", kind: String? = "movie", known: Bool = true) {
        pending.removeValue(forKey: index)?.resume(returning: known ? ProgressReply(itemId: item, mediaType: kind) : nil)
    }
}

@MainActor
final class PostPlayCompletionTests: XCTestCase {
    func until(_ predicate: () -> Bool) async { for _ in 0..<1000 where !predicate() { await Task.yield() } }
    private var body: [String: Any] { ["mediaType": "movie", "playbackEnded": true, "position": 120, "duration": 120] }
    func testActualWriterSealsSynchronouslyThenDrainsOldWriteBeforeFinalCanonicalAck() async throws {
        let api = PostPlayProgressFixture(), writer = PlayerProgressWriter(viewer: api.context, api: api)
        XCTAssertTrue(writer.submit(["mediaType": "movie", "playbackEnded": false], ended: false))
        await until { api.pending[0] != nil }
        let completed = writer.beginCompletion(body)
        XCTAssertFalse(writer.accepting); XCTAssertFalse(writer.submit(body, ended: true)); XCTAssertEqual(api.calls.count, 1)
        api.finish(0); await until { api.pending[1] != nil }
        XCTAssertEqual(api.calls[1]["playbackEnded"] as? Bool, true); api.finish(1, item: "server-canonical-film")
        let receipt = try await completed.value.get()
        XCTAssertEqual(receipt.itemID, "server-canonical-film"); XCTAssertEqual(receipt.context, api.context); XCTAssertEqual(api.calls.count, 2)
    }
    func testRepeatedCompletionAndFinishUseOneActualFinalRequest() async throws {
        let api = PostPlayProgressFixture(), writer = PlayerProgressWriter(viewer: api.context, api: api)
        let first = writer.beginCompletion(body), duplicate = writer.beginCompletion(body)
        await until { api.pending[0] != nil }; XCTAssertFalse(writer.submit(body, ended: true)); api.finish(0)
        let one = try await first.value.get(), two = try await duplicate.value.get()
        XCTAssertEqual(one.itemID, two.itemID)
        XCTAssertEqual(api.calls.count, 1)
    }
    func testUnknownOlderWritePreventsFinalRequestAndCannotBeReplayed() async {
        let api = PostPlayProgressFixture(), writer = PlayerProgressWriter(viewer: api.context, api: api)
        writer.submit(["mediaType": "movie", "playbackEnded": false], ended: false); await until { api.pending[0] != nil }
        let completed = writer.beginCompletion(body); api.finish(0, known: false)
        if case .success = await completed.value { XCTFail("Unknown progress cannot mint completion") }
        if case .success = await writer.beginCompletion(body).value { XCTFail("Unknown completion cannot replay") }
        XCTAssertEqual(api.calls.count, 1); XCTAssertTrue(writer.hasUnconfirmedWrite)
    }
    func testMissingOrWrongCanonicalFinalReplyIsUnknownNotInventedFromRequest() async {
        for (item, kind) in [(String?.none, "movie"), ("canonical", "episode")] {
            let api = PostPlayProgressFixture(), writer = PlayerProgressWriter(viewer: api.context, api: api)
            let completed = writer.beginCompletion(body); await until { api.pending[0] != nil }; api.finish(0, item: item, kind: kind)
            if case .success = await completed.value { XCTFail("Canonical final identity required") }
            XCTAssertTrue(writer.hasUnconfirmedWrite); XCTAssertEqual(api.calls.count, 1)
        }
    }
    func testOriginalViewerSwitchDuringDrainCannotSendFinalAsReplacement() async {
        let api = PostPlayProgressFixture(), writer = PlayerProgressWriter(viewer: api.context, api: api)
        writer.submit(["mediaType": "movie", "playbackEnded": false], ended: false); await until { api.pending[0] != nil }
        let original = api.context, completed = writer.beginCompletion(body)
        api.context = PostPlayFixture.context("replacement"); api.finish(0)
        if case .success = await completed.value { XCTFail("Changed viewer cannot complete old source") }
        XCTAssertEqual(api.calls.count, 1); XCTAssertEqual(api.viewers, [original])
    }
    func testExistingDrainAlsoJoinsTheNewActualFinalWrite() async throws {
        let api = PostPlayProgressFixture(), writer = PlayerProgressWriter(viewer: api.context, api: api)
        let completed = writer.beginCompletion(body); await until { api.pending[0] != nil }
        var drained = false
        let drain = Task { try await writer.stopAndDrain(requireKnownAcknowledgements: true); drained = true }
        await Task.yield(); XCTAssertFalse(drained); api.finish(0)
        _ = try await completed.value.get(); try await drain.value; XCTAssertTrue(drained)
    }
    func testActualEndPolicyRequiresGenuineEndAndClaimsOnlyOnce() throws {
        let policy = PostPlayEndPolicy(), request = try PostPlayFixture.request()
        XCTAssertFalse(policy.claim(request: request, position: 30, duration: 120, live: false, failed: false, discarded: false, offline: false, reportsProgress: true))
        XCTAssertTrue(policy.claim(request: request, position: 119, duration: 120, live: false, failed: false, discarded: false, offline: false, reportsProgress: true))
        XCTAssertFalse(policy.claim(request: request, position: 120, duration: 120, live: false, failed: false, discarded: false, offline: false, reportsProgress: true))
    }
    func testErrorManualCloseOfflineLiveAndNonReportingPlaybackCannotOffer() throws {
        let request = try PostPlayFixture.request()
        for (live, failed, discarded, offline, reports) in [(true, false, false, false, true), (false, true, false, false, true), (false, false, true, false, true), (false, false, false, true, true), (false, false, false, false, false)] {
            XCTAssertFalse(PostPlayEndPolicy().claim(request: request, position: 120, duration: 120, live: live, failed: failed, discarded: discarded, offline: offline, reportsProgress: reports))
        }
        for duration in [0.0, Double.nan, Double.infinity] { XCTAssertFalse(PostPlayEndPolicy().claim(request: request, position: 120, duration: duration, live: false, failed: false, discarded: false, offline: false, reportsProgress: true)) }
    }
    func testNormalEpisodeWithNextNeverAsksForSeriesRating() throws {
        let episodes = try [PostPlayFixture.episode(), PostPlayFixture.episode(2)]
        let request = try PostPlayFixture.request(series: true, episodes: episodes, selected: episodes[0])
        XCTAssertNotNil(request.nextEpisode)
        XCTAssertFalse(PostPlayEndPolicy().claim(request: request, position: 120, duration: 120, live: false, failed: false, discarded: false, offline: false, reportsProgress: true))
    }
    func testKnownFinalEpisodeCanOfferButMissingOrderAndFileOnlyCannot() throws {
        let final = try PostPlayFixture.request(series: true, lifecycle: "Ended")
        XCTAssertTrue(PostPlayEndPolicy().claim(request: final, position: 120, duration: 120, live: false, failed: false, discarded: false, offline: false, reportsProgress: true))
        var unknown = final; unknown.postPlayStamp = nil
        XCTAssertFalse(PostPlayEndPolicy().claim(request: unknown, position: 120, duration: 120, live: false, failed: false, discarded: false, offline: false, reportsProgress: true))
        var file = try PostPlayFixture.request(); file.fileOnlyPlayback = true
        XCTAssertFalse(PostPlayEndPolicy().claim(request: file, position: 120, duration: 120, live: false, failed: false, discarded: false, offline: false, reportsProgress: true))
    }
    func testOldCompletionOperationCannotPublishOverReplacementOperation() {
        let coordinator = PlaybackCoordinator(), first = UUID(), replacement = UUID()
        let old = coordinator.beginPostPlay(first); XCTAssertTrue(coordinator.postPlayOperationCurrent(old))
        _ = coordinator.beginPostPlay(replacement)
        XCTAssertFalse(coordinator.postPlayOperationCurrent(old)); XCTAssertTrue(coordinator.postPlayOperationCurrent(replacement))
        coordinator.dismissPostPlay(first); XCTAssertTrue(coordinator.postPlayOperationCurrent(replacement))
        coordinator.retirePostPlay(); XCTAssertFalse(coordinator.postPlayOperationCurrent(replacement))
    }
    func testConsumedCompletionPipelineCannotReadContextBeforeCanonicalAcknowledgement() async throws {
        let progress = PostPlayProgressFixture(), writer = PlayerProgressWriter(viewer: progress.context, api: progress)
        let final = writer.beginCompletion(body), id = UUID(), request = try PostPlayFixture.request()
        let produced = Task { await PostPlayCompletionPipeline.offer(after: final, request: request, original: progress.context, id: id, current: { $0 == progress.context }) }
        let api = PostPlayFixtureAPI()
        await until { progress.pending[0] != nil }; XCTAssertTrue(api.calls.isEmpty)
        progress.finish(0, item: "canonical-after-drain")
        let reply = await produced.value
        let offer = try XCTUnwrap(reply)
        XCTAssertEqual(offer.completion?.itemID, "canonical-after-drain")
        let model = PostPlayModel(offer: offer, api: api); defer { model.close() }
        model.load(); await until { !model.loading }
        XCTAssertEqual(api.calls, ["context", "suggestions:none"])
    }
    func testConsumedPipelineReturnsUnavailableWithoutContextReadAfterUnknownAck() async throws {
        let progress = PostPlayProgressFixture(), writer = PlayerProgressWriter(viewer: progress.context, api: progress)
        let final = writer.beginCompletion(body), request = try PostPlayFixture.request()
        let produced = Task { await PostPlayCompletionPipeline.offer(after: final, request: request, original: progress.context, id: UUID(), current: { $0 == progress.context }) }
        await until { progress.pending[0] != nil }; progress.finish(0, known: false)
        let reply = await produced.value
        let offer = try XCTUnwrap(reply), api = PostPlayFixtureAPI()
        let model = PostPlayModel(offer: offer, api: api); model.load()
        XCTAssertTrue(api.calls.isEmpty); XCTAssertNil(model.rating); XCTAssertNotNil(model.error); model.close()
    }
    func testConsumedPipelineCannotPublishKnownAckAfterOriginalViewerChanged() async throws {
        let progress = PostPlayProgressFixture(), writer = PlayerProgressWriter(viewer: progress.context, api: progress)
        let original = progress.context, final = writer.beginCompletion(body), request = try PostPlayFixture.request()
        let produced = Task { await PostPlayCompletionPipeline.offer(after: final, request: request, original: original, id: UUID(), current: { $0 == progress.context }) }
        await until { progress.pending[0] != nil }; progress.context = PostPlayFixture.context("replacement"); progress.finish(0)
        let result = await produced.value; XCTAssertNil(result)
    }

}
