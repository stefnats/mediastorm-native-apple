import Foundation

struct RecordingObservedData: Sendable {
    let data: Data
    let date: String
    let started: ContinuousClock.Instant
    let received: ContinuousClock.Instant
    let budgetMS: Int
    func clock() throws -> RecordingResponseClock {
        try RecordingResponseClock(date: date, started: started, received: received, budgetMS: budgetMS)
    }
}

/// One real bounded URLSession resource. Completion joins invalidation, including
/// cancellation and a bounded body; losing an acknowledgement never replays POST.
final class RecordingBoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Capacity: @unchecked Sendable {
        let lock = NSLock()
        var used = 0
    }
    private static let capacity = Capacity()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RecordingObservedData, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var expected: URL?
    private var started = ContinuousClock.now
    private var bytes = Data()
    private var date: String?
    private var outcome: Result<RecordingObservedData, Error>?
    private var failure: Error?
    private var cancelled = false
    private var charged = false
    private var budgetMS = 15_000
    private var maximumBytes = 65_536

    static func send(_ request: URLRequest, seconds: Int, maximumBytes: Int = 65_536) async throws -> RecordingObservedData {
        guard [15, 330].contains(seconds), [65_536, 524_288].contains(maximumBytes), request.url != nil else { throw RecordingDataError.unavailable }
        let operation = RecordingBoundedRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in operation.start(request, seconds: seconds, maximumBytes: maximumBytes, continuation: continuation) }
        } onCancel: { operation.cancel() }
    }
    static func configuration(seconds: Int) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeInterval(seconds)
        config.timeoutIntervalForResource = TimeInterval(seconds)
        config.waitsForConnectivity = false
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return config
    }
    private func start(_ request: URLRequest, seconds: Int, maximumBytes: Int, continuation: CheckedContinuation<RecordingObservedData, Error>) {
        Self.capacity.lock.lock()
        let available = Self.capacity.used < 2
        if available { Self.capacity.used += 1 }
        Self.capacity.lock.unlock()
        guard available else { continuation.resume(throwing: RecordingDataError.unavailable); return }
        lock.lock()
        if cancelled {
            lock.unlock(); Self.capacity.lock.lock(); Self.capacity.used -= 1; Self.capacity.lock.unlock()
            continuation.resume(throwing: CancellationError()); return
        }
        charged = true; self.continuation = continuation; expected = request.url
        budgetMS = seconds * 1000; self.maximumBytes = maximumBytes; started = .now
        let config = Self.configuration(seconds: seconds)
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        var request = request; request.timeoutInterval = TimeInterval(seconds)
        let task = session.dataTask(with: request)
        self.session = session; self.task = task
        lock.unlock(); task.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let work = task; lock.unlock()
        work?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let http = response as? HTTPURLResponse
        let accepted = !cancelled && response.url == expected && http?.statusCode == 200 &&
            response.mimeType == "application/json" && (response.expectedContentLength < 0 || response.expectedContentLength <= maximumBytes)
        if accepted { date = http?.value(forHTTPHeaderField: "Date") }
        else { failure = RecordingDataError.unavailable }
        lock.unlock()
        completionHandler(accepted ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let overflow = bytes.count + data.count > maximumBytes
        if overflow { failure = RecordingDataError.unavailable; bytes.removeAll(keepingCapacity: false) }
        else if failure == nil && !cancelled { bytes.append(data) }
        lock.unlock()
        if overflow { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if cancelled { outcome = .failure(CancellationError()) }
        else if let error = failure ?? error { outcome = .failure(error) }
        else if let date {
            outcome = .success(RecordingObservedData(data: bytes, date: date, started: started, received: .now, budgetMS: budgetMS))
        } else { outcome = .failure(RecordingDataError.unavailable) }
        bytes.removeAll(keepingCapacity: false)
        lock.unlock()
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        let callback = continuation
        continuation = nil
        let result = outcome ?? .failure(error ?? RecordingDataError.unavailable)
        let refund = charged; charged = false
        self.session = nil; task = nil; outcome = nil
        lock.unlock()
        if refund { Self.capacity.lock.lock(); Self.capacity.used -= 1; Self.capacity.lock.unlock() }
        callback?.resume(with: result)
    }
}

@MainActor
protocol RecordingDerivedAPI: RecordingSourceAPI {
    func isCurrent(_ context: SourceActionContext) -> Bool
    func validateDerivedSource(_ source: RecordingDerivedSource) async throws
    func derived(_ source: RecordingDerivedSource, prepare: Bool, previous: RecordingDerivedObservation?) async throws -> RecordingDerivedObservation
}

extension RecordingDerivedAPI {
    func validateDerivedSource(_ source: RecordingDerivedSource) async throws {
        guard isCurrent(source.context) else { throw RecordingDataError.unavailable }
        let latest = try await recording(source.recording.id, context: source.context)
        try Task.checkCancellation()
        guard isCurrent(source.context), latest == source.recording else { throw RecordingDataError.unavailable }
    }
}

extension APIClient: RecordingDerivedAPI {
    func validateDerivedSource(_ source: RecordingDerivedSource) async throws {
        try requireSourceContext(source.context)
        let request = try source.context.request("GET", path: "/api/live/recordings/\(Self.segment(source.recording.id))")
        let raw = try await RecordingBoundedRequest.send(request, seconds: 15, maximumBytes: 524_288)
        try requireSourceContext(source.context)
        let latest = try decoder.decode(Recording.self, from: raw.data)
        guard latest == source.recording else { throw RecordingDataError.unavailable }
        try requireSourceContext(source.context)
    }
    func derived(_ source: RecordingDerivedSource, prepare: Bool, previous: RecordingDerivedObservation?) async throws -> RecordingDerivedObservation {
        try requireSourceContext(source.context)
        let request = try Self.recordingDerivedRequest(source, prepare: prepare)
        let raw = try await RecordingBoundedRequest.send(request, seconds: prepare ? 330 : 15)
        try requireSourceContext(source.context)
        let observation = try RecordingDerivedObservation(source: source, descriptor: RecordingDerivedDescriptor.decode(raw.data, source: source),
            clock: raw.clock(), previous: previous)
        try requireSourceContext(source.context)
        return observation
    }
    static func recordingDerivedRequest(_ source: RecordingDerivedSource, prepare: Bool) throws -> URLRequest {
        let path = "/api/live/recordings/\(segment(source.recording.id))/derived" + (prepare ? "/join" : "")
        return try source.context.request(prepare ? "POST" : "GET", path: path)
    }
    static func recordingDerivedMediaRequest(_ observation: RecordingDerivedObservation) throws -> URLRequest {
        guard observation.ready(), let artifact = observation.descriptor.id, RecordingWire.hex(artifact, count: 32) else { throw RecordingDataError.unavailable }
        return try observation.source.context.request("GET", path: "/api/live/recordings/\(segment(observation.source.recording.id))/derived/\(artifact)/stream")
    }
}
