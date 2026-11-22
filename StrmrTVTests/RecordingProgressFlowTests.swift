import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class RecordingDVRStore {
    enum Failure: Error { case conflict, unknownAcknowledgement }
    var revision: Int64 = 0
    var generation: Int64 = 0
    var position: Int64?
    func apply(_ command: RecordingProgressCommand) throws -> RecordingProgressReceipt {
        guard command.revision.value == revision, command.writerGeneration.value == generation else { throw Failure.conflict }
        let receipt = try RecordingDVRFixture.result(command)
        revision = receipt.revision.value; generation = receipt.writerGeneration.value; position = receipt.positionMs
        return receipt
    }
}

/// Deferred API calls return the actual production DTO/receipt parser results.
/// This finite fixture tests the client CAS chain, not Go/PG authorization.
@MainActor
final class RecordingDVRAPI: RecordingProgressAPI {
    let original: RecordingDerivedObservation
    let store: RecordingDVRStore
    var context: SourceActionContext
    var events: [String] = []
    var commands: [RecordingProgressCommand] = []
    var holdWrites = false
    var loseAcknowledgement = false
    var pending: [(RecordingProgressCommand, CheckedContinuation<RecordingProgressReceipt, Error>)] = []
    var holdSource = false
    var pendingSource: CheckedContinuation<Recording, Never>?
    init(_ original: RecordingDerivedObservation, store: RecordingDVRStore = RecordingDVRStore()) {
        self.original = original; self.store = store; context = original.source.context
    }
    func sourceContext() -> SourceActionContext { context }
    func isCurrent(_ context: SourceActionContext) -> Bool { self.context == context }
    func recording(_ id: String, context: SourceActionContext) async throws -> Recording {
        events.append("source")
        if holdSource { return await withCheckedContinuation { pendingSource = $0 } }
        return original.source.recording
    }
    func derived(_ source: RecordingDerivedSource, prepare: Bool, previous: RecordingDerivedObservation?) async throws -> RecordingDerivedObservation {
        events.append(prepare ? "join" : "descriptor")
        return original
    }
    func readRecordingProgress(_ original: RecordingDerivedObservation, history: Bool) async throws -> RecordingProgressSnapshot {
        events.append("read")
        guard isCurrent(original.source.context) else { throw RecordingDataError.unavailable }
        return try RecordingDVRFixture.snapshot(original, revision: String(store.revision), generation: String(store.generation), position: store.position, history: history)
    }
    func writeRecordingProgress(_ command: RecordingProgressCommand) async throws -> RecordingProgressReceipt {
        guard isCurrent(command.original.source.context) else { throw RecordingDataError.unavailable }
        try command.beginAttempt()
        commands.append(command); events.append(command.action)
        if holdWrites { return try await withCheckedThrowingContinuation { pending.append((command, $0)) } }
        let receipt = try store.apply(command)
        if loseAcknowledgement { throw RecordingDVRStore.Failure.unknownAcknowledgement }
        return receipt
    }
    func finishNext() throws {
        guard !pending.isEmpty else { throw RecordingDataError.unavailable }
        let (command, callback) = pending.removeFirst()
        do {
            let receipt = try store.apply(command)
            if loseAcknowledgement { throw RecordingDVRStore.Failure.unknownAcknowledgement }
            callback.resume(returning: receipt)
        } catch { callback.resume(throwing: error) }
    }
    func initial(position: Int64 = 0) async throws -> RecordingProgressReceipt {
        store.position = position
        let snapshot = try await readRecordingProgress(original, history: false)
        let command = try RecordingProgressCommand.claim(snapshot, action: "resume")
        return try await writeRecordingProgress(command)
    }
}

@MainActor
final class RecordingProgressFlowTests: XCTestCase {
    private func until(_ predicate: () -> Bool) async { for _ in 0..<1000 { if !predicate() { await Task.yield() } } }

    func testDetailAppearanceNeverAutomaticallyPreparesOrClaims() async throws {
        let original = try RecordingDVRFixture.observation(), api = RecordingDVRAPI(original)
        let model = RecordingDerivedModel(recording: original.source.recording, context: api.context, api: api)
        XCTAssertTrue(api.events.isEmpty)
        model.readStatus()
        await until { !model.busy }
        XCTAssertEqual(api.events, ["source", "descriptor"])
        model.readStatus(prepare: true)
        await until { !model.busy }
        XCTAssertEqual(api.events, ["source", "descriptor", "source", "join"])
        model.readProgress()
        await until { !model.busy }
        XCTAssertEqual(api.events.last, "read"); XCTAssertNotNil(model.snapshot)
        XCTAssertTrue(api.commands.isEmpty)
    }
    func testClosedDetailCannotPublishMaskedLateCaptureReadOrPrepare() async throws {
        let original = try RecordingDVRFixture.observation(), api = RecordingDVRAPI(original)
        api.holdSource = true
        let model = RecordingDerivedModel(recording: original.source.recording, context: api.context, api: api)
        model.readStatus(prepare: true)
        await until { api.pendingSource != nil }
        XCTAssertNotNil(api.pendingSource)
        model.close()
        let callback = api.pendingSource; api.pendingSource = nil; callback?.resume(returning: original.source.recording)
        await until { !model.busy }
        XCTAssertEqual(api.events, ["source"]); XCTAssertNil(model.observation)
    }
    func testQueuedOldProfileOrRenewedProofDoesNotDemandAsNewContext() async throws {
        let original = try RecordingDVRFixture.observation(), api = RecordingDVRAPI(original)
        let model = RecordingDerivedModel(recording: original.source.recording, context: api.context, api: api)
        api.context = RecordingDVRFixture.context(proof: "new-proof")
        model.readStatus(prepare: true)
        await until { !model.busy }
        XCTAssertTrue(api.events.isEmpty); XCTAssertNil(model.observation)
    }
    func testSerialWriterCoalescesToLatestActualPositionAndUsesExactAcknowledgedCounters() async throws {
        let original = try RecordingDVRFixture.observation(), api = RecordingDVRAPI(original)
        let initial = try await api.initial()
        api.holdWrites = true
        let writer = RecordingProgressWriter(initial, api: api)
        writer.offer(1000)
        await until { api.pending.count == 1 }
        writer.offer(2000); writer.offer(3000)
        XCTAssertEqual(api.pending.count, 1)
        try api.finishNext()
        await until { api.pending.count == 1 }
        XCTAssertEqual(api.commands.last?.positionMs, 3000)
        XCTAssertEqual(api.commands.last?.revision.wire, "2")
        try api.finishNext()
        await until { writer.acknowledged.positionMs == 3000 }
        await writer.close(finalPosition: nil)
        XCTAssertEqual(api.commands.map(\.action), ["resume", "touch", "touch"])
        XCTAssertEqual(api.store.position, 3000)
    }
    func testNormalCloseJoinsAdmittedWriteThenAtMostOneFinalRealSample() async throws {
        let original = try RecordingDVRFixture.observation(), api = RecordingDVRAPI(original), initial = try await api.initial()
        api.holdWrites = true
        let writer = RecordingProgressWriter(initial, api: api)
        writer.offer(1234)
        await until { api.pending.count == 1 }
        writer.offer(5555)
        let closing = Task { await writer.close(finalPosition: 2345) }
        await until { !writer.accepting }
        writer.offer(9999)
        XCTAssertEqual(api.pending.count, 1)
        try api.finishNext()
        await until { api.pending.count == 1 }
        XCTAssertEqual(api.commands.last?.positionMs, 2345)
        try api.finishNext()
        await closing.value
        await writer.close(finalPosition: 60_000)
        XCTAssertEqual(api.commands.map(\.positionMs), [0, 1234, 2345])
        XCTAssertEqual(api.store.position, 2345)
    }
    func testLostAcknowledgementRetiresChainWithoutAutomaticReplayOrFinalOverwrite() async throws {
        let original = try RecordingDVRFixture.observation(), api = RecordingDVRAPI(original), initial = try await api.initial()
        api.loseAcknowledgement = true
        let writer = RecordingProgressWriter(initial, api: api)
        writer.offer(7000)
        await until { writer.failed }
        XCTAssertTrue(writer.failed); XCTAssertEqual(api.store.position, 7000, "The server may already have committed an unknown POST")
        writer.offer(8000); await writer.close(finalPosition: 9000)
        XCTAssertEqual(api.commands.count, 2); XCTAssertEqual(writer.acknowledged.positionMs, 0)
    }
    func testSecondIndependentClientResumesAndOldWriterCannotOverwriteItsNewGeneration() async throws {
        let original = try RecordingDVRFixture.observation(), store = RecordingDVRStore()
        let a = RecordingDVRAPI(original, store: store), b = RecordingDVRAPI(original, store: store)
        let first = try await a.initial()
        let writer = RecordingProgressWriter(first, api: a)
        writer.offer(12_345)
        await until { writer.acknowledged.positionMs == 12_345 }
        let readB = try await b.readRecordingProgress(original, history: false)
        XCTAssertEqual(readB.positionMs, 12_345)
        let resumedB = try await b.writeRecordingProgress(RecordingProgressCommand.claim(readB, action: "resume"))
        XCTAssertEqual(resumedB.positionMs, 12_345); XCTAssertEqual(resumedB.writerGeneration.wire, "2")
        writer.offer(30_000)
        await until { writer.failed }
        await writer.close(finalPosition: 60_000)
        XCTAssertTrue(writer.failed); XCTAssertEqual(store.position, 12_345); XCTAssertEqual(store.generation, 2)
    }
    func testContextChangeDuringActualWriteCannotPublishAcknowledgementOrCreateFinalRequest() async throws {
        let original = try RecordingDVRFixture.observation(), api = RecordingDVRAPI(original), initial = try await api.initial()
        api.holdWrites = true
        let writer = RecordingProgressWriter(initial, api: api)
        writer.offer(1000)
        await until { api.pending.count == 1 }
        api.context = RecordingDVRFixture.context("replacement")
        try api.finishNext()
        await until { writer.failed }
        await writer.close(finalPosition: 2000)
        XCTAssertEqual(writer.acknowledged.positionMs, 0); XCTAssertEqual(api.commands.count, 2)
    }
    func testPrematureEndFinalSaveUsesActualPositionAndNeverManufacturesDuration() async throws {
        let original = try RecordingDVRFixture.observation(), api = RecordingDVRAPI(original), initial = try await api.initial()
        let writer = RecordingProgressWriter(initial, api: api)
        await writer.close(finalPosition: 17_000)
        XCTAssertEqual(api.store.position, 17_000); XCTAssertEqual(api.commands.last?.expectedPositionMs, 17_000)
    }
}
