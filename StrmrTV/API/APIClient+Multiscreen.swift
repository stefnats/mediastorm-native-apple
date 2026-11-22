import Foundation

/// What multiscreen needs from the server beyond the live player's calls: a channel opened as
/// an HLS session whatever the server would pick, a strict stop, and the provider's stream usage.
extension APIClient: LiveMultiscreenAPI {
    /// Opens `channel` as an HLS session (`format=hls`). The session ID comes back even when
    /// the answer has no playable playlist, so the caller can still stop it.
    func startLiveHLS(_ channel: LiveChannel, attempt: LivePlaybackAttempt) async throws -> (sessionID: String?, url: URL?) {
        let start = try await openLiveStart(channel, programTitle: nil, forceHLS: true, target: "native", attempt: attempt)
        let url = start.playlistUrl.flatMap { $0.isEmpty || start.isDirect == true ? nil : try? mediaURL(apiPath: $0, context: attempt.context) }
        return (start.sessionId.flatMap { $0.isEmpty ? nil : $0 }, url)
    }

    /// `stopLiveSession` that reports failure, so a release can be retried.
    func stopLiveSessionStrict(_ sessionID: String, context: SourceActionContext? = nil) async throws {
        if let context {
            guard KidsLiveOpened.validSession(sessionID) else { throw APIError.notReady("Invalid live session") }
            var request = try context.request("POST", path: "/api/video/hls/\(Self.segment(sessionID))/stop")
            request.timeoutInterval = 10
            _ = try await sendOriginalSourceAction(request)
            return
        }
        try await sendRaw("POST", "/api/video/hls/\(Self.segment(sessionID))/stop", promptOnLock: false, timeout: 10)
    }

    /// The live provider's stream usage, for `sourceID` when one is picked.
    func liveUsage(sourceID: String?) async throws -> LiveUsage {
        var query = ["profileId": profileID]
        if let sourceID = sourceID?.trimmingCharacters(in: .whitespaces), !sourceID.isEmpty, sourceID != "all" {
            query["sourceId"] = sourceID
        }
        return try await send("GET", "/api/live/usage", query: query, timeout: 15)
    }
}

/// `GET /api/live/usage`.
struct LiveUsage: Decodable, Equatable {
    let currentStreams: Double
    let maxStreams: Double
    let availableStreams: Double
    let atLimit: Bool

    /// Room for one more stream: no limit (`maxStreams <= 0`), or a free one under it.
    var hasCapacity: Bool {
        !atLimit && maxStreams.isFinite
            && (maxStreams <= 0 || (availableStreams > 0 && currentStreams < maxStreams))
    }
}
