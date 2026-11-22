import Foundation
import XCTest
@testable import StrmrTV

private final class ReportHTTPExchange: @unchecked Sendable {
    let started = XCTestExpectation(description: "Actual URLSession POST entered URLProtocol")
    let cancelled = XCTestExpectation(description: "URLSession cancelled the original HTTP task")
    private let lock = NSLock()
    private var pending: URLProtocol?
    private var stopped = false
    private var requests: [URLRequest] = []

    func receive(_ handler: URLProtocol) {
        lock.lock()
        requests.append(handler.request)
        let post = handler.request.httpMethod == "POST"
        if post { pending = handler }
        lock.unlock()
        if post { started.fulfill() }
        else { respond(handler, status: 204, data: Data()) }
    }
    func stop(_ handler: URLProtocol) {
        lock.lock()
        let cancelledPost = pending === handler
        if cancelledPost { stopped = true; pending = nil }
        lock.unlock()
        if cancelledPost { cancelled.fulfill() }
    }
    var postWasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
    var recorded: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    func acknowledge() {
        lock.lock()
        let handler = pending
        pending = nil
        lock.unlock()
        guard let handler else { return }
        respond(handler, status: 200, data: Data(#"{"replacement":{"prequeueId":"late-http-id","status":"queued"},"resumePosition":0}"#.utf8))
    }
    private func respond(_ handler: URLProtocol, status: Int, data: Data) {
        let response = HTTPURLResponse(url: handler.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        handler.client?.urlProtocol(handler, didReceive: response, cacheStoragePolicy: .notAllowed)
        handler.client?.urlProtocol(handler, didLoad: data)
        handler.client?.urlProtocolDidFinishLoading(handler)
    }
}

private final class ReportHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [String: ReportHTTPExchange] = [:]
    func install(_ exchange: ReportHTTPExchange, key: String) { lock.lock(); exchanges[key] = exchange; lock.unlock() }
    func remove(_ key: String) { lock.lock(); exchanges[key] = nil; lock.unlock() }
    func lookup(_ key: String) -> ReportHTTPExchange? { lock.lock(); defer { lock.unlock() }; return exchanges[key] }
}

private final class HeldReportHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ReportHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let exchange = Self.registry.lookup(request.url?.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        exchange.receive(self)
    }
    override func stopLoading() { Self.registry.lookup(request.url?.host ?? "")?.stop(self) }
}

@MainActor
final class ReleaseReportTransportTests: XCTestCase {
    @MainActor
    private final class HTTPAPI: ReleaseReportAPI {
        let session: URLSession
        let context: SourceActionContext
        init(key: String) {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [HeldReportHTTPProtocol.self]
            config.timeoutIntervalForResource = 5
            config.timeoutIntervalForRequest = 5
            session = URLSession(configuration: config)
            context = SourceActionContext(baseURL: URL(string: "https://\(key)")!,
                profileID: "original-profile", clientID: "original-client", sessionToken: "synthetic-original")
        }
        func sourceContext() -> SourceActionContext { context }
        func isCurrent(_ value: SourceActionContext) -> Bool { value == context }
        func releaseReportOptions(_ id: String, context: SourceActionContext) async throws -> ReleaseReportOptions {
            ReleaseReportOptions(sourceVersion: "original-version", releaseName: "Synthetic", audioLanguage: "deu",
                audioTracks: [], selectedAudioTrack: -1, canShare: false, hasEpisode: false, canResetHistory: false)
        }
        func submitReleaseAction(_ id: String, options: ReleaseReportOptions, submission: ReleaseReportSubmission,
                                 context: SourceActionContext) async throws -> ReleaseReportReply {
            let request = try context.request("POST", path: "/api/playback/prequeue/\(id)/retry",
                body: submission.body(options: options, clientID: context.clientID))
            // Same real async URLSession cancellation seam as APIClient.
            let (data, _) = try await session.data(for: request)
            return try JSONDecoder().decode(ReleaseReportReply.self, from: data)
        }
        func releaseReplacementStatus(_ id: String, context: SourceActionContext) async throws -> PrequeueStatus {
            throw APIError.notReady("Closed dialogs must not poll a replacement")
        }
        func cancelReleaseReplacement(_ id: String, context: SourceActionContext) async throws {
            _ = try await session.data(for: context.request("DELETE", path: "/api/playback/prequeue/\(id)/retry"))
        }
        func deleteReleaseReport(_ id: String, context: SourceActionContext) async throws { }
    }

    func testFixtureObservesActualURLSessionTaskCancellation() async throws {
        let key = UUID().uuidString.lowercased() + ".invalid"
        let exchange = ReportHTTPExchange()
        HeldReportHTTPProtocol.registry.install(exchange, key: key)
        let api = HTTPAPI(key: key)
        defer { api.session.invalidateAndCancel(); HeldReportHTTPProtocol.registry.remove(key) }
        let task = Task {
            let options = try await api.releaseReportOptions("original", context: api.context)
            return try await api.submitReleaseAction("original", options: options,
                submission: .init(reason: nil, retry: true, resetHistory: false, audioTrackIndex: nil, position: 0), context: api.context)
        }
        let started = await XCTWaiter.fulfillment(of: [exchange.started], timeout: 2)
        XCTAssertEqual(started, .completed)
        task.cancel()
        do { _ = try await task.value; XCTFail("The actual URLSession request ignored cancellation") }
        catch {
            let cancelled = await XCTWaiter.fulfillment(of: [exchange.cancelled], timeout: 2)
            XCTAssertEqual(cancelled, .completed)
            XCTAssertTrue(exchange.postWasCancelled)
        }
    }

    func testDialogCloseObservesActualLateHTTPReceiptBeforeOriginalCleanup() async {
        let key = UUID().uuidString.lowercased() + ".invalid"
        let exchange = ReportHTTPExchange()
        HeldReportHTTPProtocol.registry.install(exchange, key: key)
        let api = HTTPAPI(key: key)
        defer { api.session.invalidateAndCancel(); HeldReportHTTPProtocol.registry.remove(key) }
        let model = ReleaseReportModel(prequeueID: "original", api: api, ownership: ReleaseReplacementOwnership())
        model.load()
        await model.waitForOperation()
        model.submit(.init(reason: nil, retry: true, resetHistory: false, audioTrackIndex: nil, position: 0))
        let started = await XCTWaiter.fulfillment(of: [exchange.started], timeout: 2)
        XCTAssertEqual(started, .completed)
        model.close()
        var joined = false
        let waiter = Task { await model.waitForCleanup(); joined = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(exchange.postWasCancelled, "Closing UI must not cancel an already admitted real POST")
        XCTAssertFalse(joined)
        exchange.acknowledge()
        await waiter.value
        XCTAssertTrue(joined)
        let requests = exchange.recorded
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "DELETE"])
        XCTAssertEqual(requests.last?.url?.path, "/api/playback/prequeue/late-http-id/retry")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-original")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "X-Client-ID"), "original-client")
        guard let cleanupURL = requests.last?.url else { return XCTFail("No original cleanup HTTP request") }
        XCTAssertEqual(URLComponents(url: cleanupURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "original-profile")
        XCTAssertNil(model.replacement)
        XCTAssertNil(model.savedReportID)
    }
    func testProductionSourceActionResourceDeadlineIsFiniteAndSeparate() {
        let config = APIClient.sourceActionConfiguration()
        XCTAssertEqual(config.timeoutIntervalForRequest, 30)
        XCTAssertEqual(config.timeoutIntervalForResource, 30)
        XCTAssertEqual(config.httpMaximumConnectionsPerHost, 16)
    }

}
