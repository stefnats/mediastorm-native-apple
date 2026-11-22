import Foundation

/// Original file selection only. The server still checks the actual owned file.
struct RecordingPlaybackSource: Equatable {
    enum Kind: Equatable { case legacyWhole, legacyGrowing, part(Int), singleActive(Int) }
    let recording: Recording
    let context: SourceActionContext
    let kind: Kind

    static func legacy(_ recording: Recording, context: SourceActionContext) throws -> Self {
        guard !recording.capturePresent, recording.canPlay else {
            throw APIError.notReady("Choose an actual captured recording part; no whole file is assumed.")
        }
        return Self(recording: recording, context: context, kind: recording.status == .running ? .legacyGrowing : .legacyWhole)
    }

    static func part(_ recording: Recording, index: Int, context: SourceActionContext) throws -> Self {
        guard !recording.id.isEmpty, recording.id.count <= 128,
              recording.id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              recording.userId == context.profileID,
              recording.updatedAt.flatMap(RecordingCapture.date) != nil,
              recording.playableParts.contains(where: { $0.index == index }) else {
            throw APIError.notReady("This captured part is unavailable. Refresh the recording before trying again.")
        }
        return Self(recording: recording, context: context, kind: .part(index))
    }

    static func singleActive(_ recording: Recording, context: SourceActionContext) throws -> Self {
        guard !recording.id.isEmpty, recording.id.count <= 128,
              recording.id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              recording.userId == context.profileID, recording.updatedAt.flatMap(RecordingCapture.date) != nil,
              let part = recording.singleActivePart else {
            throw APIError.notReady("The original single active part is unavailable. Refresh and choose a part again.")
        }
        return Self(recording: recording, context: context, kind: .singleActive(part.index))
    }

    func validate(current: Recording, context: SourceActionContext) throws {
        guard self.context == context, current.id == recording.id, current.userId == recording.userId else {
            throw APIError.notReady("The profile, connection or recording changed. Choose its part again.")
        }
        if case .singleActive = kind {
            _ = try Self.singleActive(current, context: context)
            guard let original = recording.singleActivePart, let latest = current.singleActivePart,
                  original.index == latest.index, original.startedAt == latest.startedAt,
                  original.streamPath == latest.streamPath, original.sourceId == latest.sourceId,
                  original.channelId == latest.channelId, recording.capture?.sourceChanges == current.capture?.sourceChanges else {
                throw APIError.notReady("The active recording part changed. Return and choose its captured part explicitly.")
            }
            return
        }
        guard current == recording else { throw APIError.notReady("The recording changed. Choose its part again.") }
        if case let .part(index) = kind {
            _ = try Self.part(current, index: index, context: context)
        } else if current.capturePresent {
            throw APIError.notReady("The recording now has captured parts. Choose one explicitly.")
        }
    }

    @MainActor func partRequest() throws -> URLRequest {
        guard case let .part(index) = kind else { throw APIError.notReady("An explicit recording part is required") }
        _ = try Self.part(recording, index: index, context: context)
        var request = try context.request("GET", path: "/api/live/recordings/\(APIClient.segment(recording.id))/stream")
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.notReady("The recording part address is unavailable")
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "part", value: String(index))]
        guard let url = components.url else { throw APIError.notReady("The recording part address is unavailable") }
        request.url = url
        return request
    }

    @MainActor func growingRequest() throws -> URLRequest {
        guard case .singleActive = kind, let part = recording.singleActivePart else {
            throw APIError.notReady("An original single active part is required")
        }
        _ = try Self.singleActive(recording, context: context)
        var request = try context.request("GET", path: "/api/video/hls/start")
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.notReady("The recording address is unavailable")
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "path", value: part.streamPath),
            URLQueryItem(name: "title", value: recording.displayTitle)]
        request.url = components.url
        request.timeoutInterval = 60
        guard request.url != nil else { throw APIError.notReady("The recording address is unavailable") }
        return request
    }
}

@MainActor
protocol RecordingSourceAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func recording(_ id: String, context: SourceActionContext) async throws -> Recording
}

extension APIClient: RecordingSourceAPI {}

/// This actual player gate is checked before every captured open or reopen.
@MainActor
final class RecordingSourceGuard {
    let source: RecordingPlaybackSource
    private let api: any RecordingSourceAPI
    private var closed = false

    init(_ source: RecordingPlaybackSource, api: any RecordingSourceAPI = APIClient.shared) {
        self.source = source
        self.api = api
    }
    func close() { closed = true }
    func requireCurrent() throws {
        try Task.checkCancellation()
        guard !closed, api.sourceContext() == source.context else {
            throw APIError.notReady("The recording player or original profile changed. Reopen its parts.")
        }
    }
    func validateForOpen() async throws {
        try requireCurrent()
        let current = try await api.recording(source.recording.id, context: source.context)
        try requireCurrent()
        try source.validate(current: current, context: api.sourceContext())
    }
}
