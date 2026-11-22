import XCTest
@testable import StrmrTV

@MainActor
final class ReleaseReportFlowTests: XCTestCase {
    @MainActor
    private final class FakeAPI: ReleaseReportAPI {
        var current = SourceActionContext(baseURL: URL(string: "https://example.invalid")!,
            profileID: "own", clientID: "client", sessionToken: "synthetic-session")
        var options = ReleaseReportOptions(sourceVersion: "version-one", releaseName: "Synthetic.Release",
            audioLanguage: "deu", audioTracks: [], selectedAudioTrack: -1,
            canShare: false, hasEpisode: true, canResetHistory: true)
        var reply = ReleaseReportReply(report: .init(id: "saved-report"), replacement: nil,
            resumePosition: nil, historyReset: nil, historyResetError: nil, retryError: nil)
        var submissions: [ReleaseReportSubmission] = []
        var cancelled: [(String, SourceActionContext)] = []
        var deleted: [String] = []
        var failSubmission = false
        var holdSubmission = false
        var holdCleanup = false
        var pending: CheckedContinuation<ReleaseReportReply, Error>?
        var pendingStatus: CheckedContinuation<PrequeueStatus, Error>?
        var holdStatus = false
        var pendingCleanup: CheckedContinuation<Void, Never>?

        func sourceContext() -> SourceActionContext { current }
        func isCurrent(_ context: SourceActionContext) -> Bool { context == current }
        func releaseReportOptions(_ id: String, context: SourceActionContext) async throws -> ReleaseReportOptions { options }
        func submitReleaseAction(_ id: String, options: ReleaseReportOptions, submission: ReleaseReportSubmission,
                                 context: SourceActionContext) async throws -> ReleaseReportReply {
            submissions.append(submission)
            if failSubmission { throw URLError(.networkConnectionLost) }
            if holdSubmission {
                // Deliberately ignores caller cancellation: tests actual late delivery.
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            return reply
        }
        func releaseReplacementStatus(_ id: String, context: SourceActionContext) async throws -> PrequeueStatus {
            if holdStatus { return try await withCheckedThrowingContinuation { pendingStatus = $0 } }
            return try JSONDecoder().decode(PrequeueStatus.self,
                from: Data("{\"prequeueId\":\"\(id)\",\"status\":\"ready\",\"streamPath\":\"synthetic/ready.mkv\"}".utf8))
        }
        func cancelReleaseReplacement(_ id: String, context: SourceActionContext) async throws {
            try Task.checkCancellation()
            cancelled.append((id, context))
            if holdCleanup { await withCheckedContinuation { pendingCleanup = $0 } }
        }
        func deleteReleaseReport(_ id: String, context: SourceActionContext) async throws { deleted.append(id) }
        func returnReceipt() {
            let continuation = pending
            pending = nil
            continuation?.resume(returning: reply)
        }
        func finishCleanup() {
            let continuation = pendingCleanup
            pendingCleanup = nil
            continuation?.resume()
        }
        func until(_ predicate: () -> Bool) async {
            for _ in 0..<1000 { if !predicate() { await Task.yield() } }
        }
    }

    @MainActor
    private final class ProgressOwner: ReleaseReportProgressOwner {
        func prepareWrongContentReport(resetHistory: Bool) async throws { }
    }
    private let progressOwner = ProgressOwner()

    private var submission: ReleaseReportSubmission {
        ReleaseReportSubmission(reason: .missingLanguage, retry: false, resetHistory: false,
                                audioTrackIndex: nil, position: 120)
    }

    private var retrySubmission: ReleaseReportSubmission {
        ReleaseReportSubmission(reason: .missingLanguage, retry: true, resetHistory: false,
                                audioTrackIndex: nil, position: 120)
    }

    private func loaded(_ api: FakeAPI) async -> ReleaseReportModel {
        let model = ReleaseReportModel(prequeueID: "original-entry", api: api, progressOwner: progressOwner,
                                       ownership: ReleaseReplacementOwnership())
        model.load()
        await model.waitForOperation()
        return model
    }

    func testOpeningDialogDoesNotReportOrPrepare() async {
        let api = FakeAPI()
        let model = await loaded(api)
        XCTAssertEqual(model.options?.sourceVersion, "version-one")
        XCTAssertTrue(api.submissions.isEmpty)
        model.close()
        await model.waitForCleanup()
        XCTAssertTrue(api.cancelled.isEmpty)
    }

    func testReportOnlyHasNoReplacementOrAutomaticSwitch() async {
        let api = FakeAPI()
        let model = await loaded(api)
        model.submit(submission)
        await model.waitForOperation()
        XCTAssertEqual(api.submissions.count, 1)
        XCTAssertEqual(api.submissions.first?.retry, false)
        XCTAssertEqual(model.savedReportID, "saved-report")
        XCTAssertNil(model.takeReplacement())
        model.close()
        await model.waitForCleanup()
        XCTAssertTrue(api.cancelled.isEmpty)
    }

    func testPartialHistoryFailureNeverTransfersReplacement() async {
        let api = FakeAPI()
        api.reply = ReleaseReportReply(report: .init(id: "saved"), replacement: .init(prequeueId: "unexpected", status: "queued"),
            resumePosition: 0, historyReset: false, historyResetError: "failed", retryError: nil)
        let model = await loaded(api)
        model.submit(ReleaseReportSubmission(reason: .wrongEpisode, retry: true, resetHistory: true,
                                             audioTrackIndex: nil, position: 120))
        await model.waitForOperation()
        XCTAssertEqual(model.savedReportID, "saved")
        XCTAssertFalse(model.alternativeAvailable)
        XCTAssertNil(model.takeReplacement())
        model.close()
        await model.waitForCleanup()
        XCTAssertEqual(api.cancelled.map { $0.0 }, ["unexpected"])
    }

    func testCancelJoinsLateReceiptAndActualIndependentCleanup() async {
        let api = FakeAPI()
        api.holdSubmission = true
        api.holdCleanup = true
        api.reply = ReleaseReportReply(report: .init(id: "saved"), replacement: .init(prequeueId: "own-next", status: "queued"),
            resumePosition: 120, historyReset: nil, historyResetError: nil, retryError: nil)
        let original = api.current
        let model = await loaded(api)
        model.submit(retrySubmission)
        await api.until { api.pending != nil }
        guard api.pending != nil else { model.close(); return XCTFail("actual POST did not enter") }
        model.close()
        api.returnReceipt()
        await api.until { api.pendingCleanup != nil }
        guard api.pendingCleanup != nil else { return XCTFail("late owned replacement was not cancelled") }
        var joined = false
        let waiter = Task { await model.waitForCleanup(); joined = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(joined)
        XCTAssertNil(model.savedReportID)
        XCTAssertNil(model.replacement)
        api.finishCleanup()
        await waiter.value
        XCTAssertTrue(joined)
        XCTAssertEqual(api.cancelled.first?.0, "own-next")
        XCTAssertEqual(api.cancelled.first?.1, original)
    }

    func testChangedProfileCannotAdoptLateReplacementOrSavedResult() async {
        let api = FakeAPI()
        api.holdSubmission = true
        api.reply = ReleaseReportReply(report: .init(id: "saved"), replacement: .init(prequeueId: "own-next", status: "queued"),
            resumePosition: 120, historyReset: nil, historyResetError: nil, retryError: nil)
        let original = api.current
        let model = await loaded(api)
        model.submit(retrySubmission)
        await api.until { api.pending != nil }
        guard api.pending != nil else { model.close(); return XCTFail("actual POST did not enter") }
        api.current = SourceActionContext(baseURL: original.baseURL, profileID: "other", clientID: "client", sessionToken: "other-session")
        api.returnReceipt()
        await model.waitForOperation()
        XCTAssertNil(model.savedReportID)
        XCTAssertNil(model.takeReplacement())
        XCTAssertEqual(api.cancelled.first?.1, original)
        model.close()
        await model.waitForCleanup()
    }

    func testDepartureBeforeSubmitPreventsNewRequest() async {
        let api = FakeAPI()
        let model = await loaded(api)
        api.current = SourceActionContext(baseURL: api.current.baseURL, profileID: "other", clientID: "client", sessionToken: "other")
        model.submit(submission)
        await model.waitForOperation()
        XCTAssertTrue(api.submissions.isEmpty)
        XCTAssertNotNil(model.message)
        model.close()
        await model.waitForCleanup()
    }

    func testUnknownAcknowledgementCannotReplaySameDialogAction() async {
        let api = FakeAPI()
        api.failSubmission = true
        let model = await loaded(api)
        model.submit(submission)
        await model.waitForOperation()
        XCTAssertTrue(model.outcomeUnknown)
        model.submit(submission)
        await model.waitForOperation()
        XCTAssertEqual(api.submissions.count, 1)
        XCTAssertNil(model.savedReportID)
        model.close()
        await model.waitForCleanup()
    }

    func testExplicitRetryTransfersOnlyKnownServerPositionOnce() async {
        let api = FakeAPI()
        api.reply = ReleaseReportReply(report: nil, replacement: .init(prequeueId: "own-next", status: "queued"),
            resumePosition: 25, historyReset: nil, historyResetError: nil, retryError: nil)
        let model = await loaded(api)
        model.submit(ReleaseReportSubmission(reason: nil, retry: true, resetHistory: false, audioTrackIndex: nil, position: 25))
        await model.waitForOperation()
        XCTAssertNil(api.submissions.first?.reason)
        let transfer = model.takeReplacement()
        XCTAssertEqual(transfer?.position, 25)
        XCTAssertNil(model.takeReplacement())
        model.close()
        await model.waitForCleanup()
        XCTAssertTrue(api.cancelled.isEmpty)
        try? await transfer?.lease.release()
    }

    func testInvalidTrackNeverReachesMutationTransport() async {
        let api = FakeAPI()
        api.options = ReleaseReportOptions(sourceVersion: "version-one", releaseName: "Synthetic.Release",
            audioLanguage: "deu", audioTracks: [.init(index: 2, language: "deu", title: nil, codec: "aac")],
            selectedAudioTrack: 2, canShare: false, hasEpisode: true, canResetHistory: true)
        let model = await loaded(api)
        model.submit(ReleaseReportSubmission(reason: .audioProblem, retry: false, resetHistory: false,
                                             audioTrackIndex: 99, position: 0))
        await model.waitForOperation()
        XCTAssertTrue(api.submissions.isEmpty)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.outcomeUnknown)
        model.close()
        await model.waitForCleanup()
    }

    func testUndoDeletesOnlyAcknowledgedReportAndDoesNotRestoreHistory() async {
        let api = FakeAPI()
        let model = await loaded(api)
        model.submit(submission)
        await model.waitForOperation()
        model.undoReport()
        await model.waitForOperation()
        XCTAssertEqual(api.deleted, ["saved-report"])
        XCTAssertNil(model.savedReportID)
        XCTAssertTrue(model.message?.contains("not restored") == true)
        model.close()
        await model.waitForCleanup()
    }
    func testAlternativeCannotTransferUntilActualReadyStatusReturns() async throws {
        let api = FakeAPI()
        api.holdStatus = true
        api.reply = ReleaseReportReply(report: nil, replacement: .init(prequeueId: "ready-next", status: "queued"),
            resumePosition: 120, historyReset: nil, historyResetError: nil, retryError: nil)
        let model = await loaded(api)
        model.submit(ReleaseReportSubmission(reason: nil, retry: true, resetHistory: false, audioTrackIndex: nil, position: 120))
        await api.until { api.pendingStatus != nil }
        XCTAssertNotNil(api.pendingStatus)
        XCTAssertFalse(model.alternativeAvailable)
        XCTAssertNil(model.takeReplacement())
        let ready = try JSONDecoder().decode(PrequeueStatus.self,
            from: Data(#"{"prequeueId":"ready-next","status":"ready","streamPath":"synthetic/ready"}"#.utf8))
        api.pendingStatus?.resume(returning: ready)
        api.pendingStatus = nil
        await model.waitForOperation()
        XCTAssertTrue(model.alternativeAvailable)
        model.close()
        await model.waitForCleanup()
    }

    func testLateClosedDialogReceiptDoesNotDeleteAlternativeTransferredByNewDialog() async {
        let ownership = ReleaseReplacementOwnership()
        let apiA = FakeAPI()
        let apiB = FakeAPI()
        apiA.holdSubmission = true
        let reply = ReleaseReportReply(report: nil, replacement: .init(prequeueId: "deduplicated", status: "queued"),
            resumePosition: 0, historyReset: nil, historyResetError: nil, retryError: nil)
        apiA.reply = reply
        apiB.reply = reply
        let a = ReleaseReportModel(prequeueID: "original-entry", api: apiA, ownership: ownership)
        let b = ReleaseReportModel(prequeueID: "original-entry", api: apiB, ownership: ownership)
        a.load(); b.load()
        await a.waitForOperation(); await b.waitForOperation()
        let retry = ReleaseReportSubmission(reason: nil, retry: true, resetHistory: false, audioTrackIndex: nil, position: 0)
        a.submit(retry)
        await apiA.until { apiA.pending != nil }
        XCTAssertNotNil(apiA.pending)
        a.close()
        b.submit(retry)
        await b.waitForOperation()
        guard let playerB = b.takeReplacement() else {
            apiA.returnReceipt(); await a.waitForCleanup(); b.close(); await b.waitForCleanup()
            return XCTFail("New dialog did not take the ready alternative")
        }
        b.close()
        await b.waitForCleanup()
        apiA.returnReceipt()
        await a.waitForCleanup()
        XCTAssertTrue(apiA.cancelled.isEmpty)
        XCTAssertTrue(apiB.cancelled.isEmpty)
        try? await playerB.lease.release()
        XCTAssertEqual(apiB.cancelled.map { $0.0 }, ["deduplicated"])
        XCTAssertEqual(apiB.cancelled.first?.1, b.context)
        XCTAssertEqual(ownership.retainedOriginals, 0)
    }

}
