import XCTest
@testable import StrmrTV

@MainActor
final class ReleaseReplacementOwnershipTests: XCTestCase {
    @MainActor
    private final class API: ReleaseReportAPI {
        var context = SourceActionContext(baseURL: URL(string: "https://example.invalid")!,
            profileID: "original", clientID: "client", sessionToken: "synthetic-original")
        var cancellations: [(String, SourceActionContext)] = []
        var pendingDelete: CheckedContinuation<Void, Error>?
        var holdDelete = false
        var failDelete = false
        func sourceContext() -> SourceActionContext { context }
        func isCurrent(_ value: SourceActionContext) -> Bool { context == value }
        func releaseReportOptions(_ id: String, context: SourceActionContext) async throws -> ReleaseReportOptions {
            throw APIError.notReady("Unused in this ownership test")
        }
        func submitReleaseAction(_ id: String, options: ReleaseReportOptions, submission: ReleaseReportSubmission,
                                 context: SourceActionContext) async throws -> ReleaseReportReply {
            throw APIError.notReady("Unused in this ownership test")
        }
        func releaseReplacementStatus(_ id: String, context: SourceActionContext) async throws -> PrequeueStatus {
            throw APIError.notReady("Unused in this ownership test")
        }
        func deleteReleaseReport(_ id: String, context: SourceActionContext) async throws { }
        func cancelReleaseReplacement(_ id: String, context: SourceActionContext) async throws {
            cancellations.append((id, context))
            if failDelete { throw URLError(.networkConnectionLost) }
            if holdDelete { try await withCheckedThrowingContinuation { pendingDelete = $0 } }
        }
        func finishDelete() { let callback = pendingDelete; pendingDelete = nil; callback?.resume() }
    }

    private func until(_ predicate: () -> Bool) async {
        for _ in 0..<1000 { if !predicate() { await Task.yield() } }
    }

    func testLateDialogACannotDeleteDeduplicatedReplacementAlreadyOwnedByPlayerB() async throws {
        let api = API()
        let original = api.context
        let ownership = ReleaseReplacementOwnership()
        // A's POST is still outstanding when B starts its retry.
        let requestA = try await ownership.begin(original: "source", context: original)
        let requestB = try await ownership.begin(original: "source", context: original)
        let playerB = try ownership.adopt("same-deduplicated-id", request: requestB, api: api, context: original)
        ownership.finish(requestB)
        // The actual late ACK from A names the very same resource as B.
        let lateA = try ownership.adopt("same-deduplicated-id", request: requestA, api: api, context: original)
        ownership.finish(requestA)
        try await lateA.release()
        XCTAssertTrue(api.cancellations.isEmpty, "B already owns the resource")
        api.context = SourceActionContext(baseURL: original.baseURL, profileID: "different", clientID: "client", sessionToken: "different")
        try await playerB.release()
        XCTAssertEqual(api.cancellations.map { $0.0 }, ["same-deduplicated-id"])
        XCTAssertEqual(api.cancellations.first?.1, original)
        XCTAssertEqual(ownership.retainedOriginals, 0, "Completed records must be removed")
    }

    func testPendingOtherPOSTDefersDeletionUntilItCanAdoptTheSameResource() async throws {
        let api = API()
        let ownership = ReleaseReplacementOwnership()
        let a = try await ownership.begin(original: "source", context: api.context)
        let b = try await ownership.begin(original: "source", context: api.context)
        let leaseA = try ownership.adopt("same", request: a, api: api, context: api.context)
        ownership.finish(a)
        try await leaseA.release()
        XCTAssertTrue(api.cancellations.isEmpty)
        let leaseB = try ownership.adopt("same", request: b, api: api, context: api.context)
        ownership.finish(b)
        XCTAssertTrue(api.cancellations.isEmpty)
        try await leaseB.release()
        XCTAssertEqual(api.cancellations.count, 1)
        XCTAssertEqual(ownership.retainedOriginals, 0)
    }

    func testAlreadyStartedDeleteIsJoinedBeforeAnotherPOSTCanBegin() async throws {
        let api = API()
        api.holdDelete = true
        let ownership = ReleaseReplacementOwnership()
        let a = try await ownership.begin(original: "source", context: api.context)
        let lease = try ownership.adopt("replacement", request: a, api: api, context: api.context)
        ownership.finish(a)
        let release = Task { try await lease.release() }
        await until { api.pendingDelete != nil }
        XCTAssertNotNil(api.pendingDelete)
        var newPOSTMayStart = false
        let begin = Task { let next = try await ownership.begin(original: "source", context: api.context); newPOSTMayStart = true; return next }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(newPOSTMayStart)
        api.finishDelete()
        try await release.value
        let next = try await begin.value
        XCTAssertTrue(newPOSTMayStart)
        ownership.finish(next)
        XCTAssertEqual(ownership.retainedOriginals, 0)
    }

    func testUnknownDeleteHasExplicitRetryStatusAndCannotStartAnotherPOST() async throws {
        let api = API()
        api.failDelete = true
        let ownership = ReleaseReplacementOwnership()
        let request = try await ownership.begin(original: "source", context: api.context)
        let lease = try ownership.adopt("replacement", request: request, api: api, context: api.context)
        ownership.finish(request)
        do { try await lease.release(); XCTFail("Unknown cancellation appeared successful") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not confirmed")) }
        do { _ = try await ownership.begin(original: "source", context: api.context); XCTFail("Unknown deletion admitted new POST") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Retry cancellation explicitly")) }
        XCTAssertEqual(api.cancellations.count, 1)
        // Uncertain records are bounded rather than forgotten on a timer and
        // accidentally allowing reuse of a resource whose DELETE may still win.
        XCTAssertEqual(ownership.retainedOriginals, 1)
        XCTAssertTrue(ownership.needsCleanupRetry(original: "source", context: api.context))
        api.failDelete = false
        try await ownership.retryCleanup(original: "source", context: api.context)
        XCTAssertEqual(ownership.retainedOriginals, 0)
        XCTAssertEqual(api.cancellations.count, 2)
    }
}
