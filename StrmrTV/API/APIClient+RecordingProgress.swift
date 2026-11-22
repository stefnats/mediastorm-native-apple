import Foundation

@MainActor
protocol RecordingProgressAPI: RecordingDerivedAPI {
    func readRecordingProgress(_ original: RecordingDerivedObservation, history: Bool) async throws -> RecordingProgressSnapshot
    func writeRecordingProgress(_ command: RecordingProgressCommand) async throws -> RecordingProgressReceipt
}

extension APIClient: RecordingProgressAPI {
    static func recordingProgressRequest(_ original: RecordingDerivedObservation, command: RecordingProgressCommand? = nil,
                                         history: Bool = false) throws -> URLRequest {
        guard original.ready(), !history || command == nil, command == nil || command?.original === original else { throw RecordingDataError.unavailable }
        var request = try original.source.context.request(command == nil ? "GET" : "POST",
            path: "/api/live/recordings/\(segment(original.source.recording.id))/progress", body: command?.body())
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw RecordingDataError.unavailable }
        // This endpoint accepts the original header credentials and no profile query.
        components.queryItems = history ? [URLQueryItem(name: "includeHistory", value: "true")] : nil
        request.url = components.url
        guard request.url != nil else { throw RecordingDataError.unavailable }
        return request
    }
    func readRecordingProgress(_ original: RecordingDerivedObservation, history: Bool) async throws -> RecordingProgressSnapshot {
        try requireSourceContext(original.source.context)
        let request = try Self.recordingProgressRequest(original, history: history)
        let raw = try await RecordingBoundedRequest.send(request, seconds: 15)
        try requireSourceContext(original.source.context)
        let value = try RecordingProgressSnapshot(original: original, raw: raw, history: history)
        try requireSourceContext(original.source.context)
        guard value.adoptable() else { throw RecordingDataError.unavailable }
        return value
    }
    func writeRecordingProgress(_ command: RecordingProgressCommand) async throws -> RecordingProgressReceipt {
        try requireSourceContext(command.original.source.context)
        try command.beginAttempt()
        let request = try Self.recordingProgressRequest(command.original, command: command)
        let raw = try await RecordingBoundedRequest.send(request, seconds: 15)
        try requireSourceContext(command.original.source.context)
        let value = try RecordingProgressReceipt(command: command, raw: raw)
        try requireSourceContext(command.original.source.context)
        guard value.adoptable() else { throw RecordingDataError.unavailable }
        return value
    }
}
