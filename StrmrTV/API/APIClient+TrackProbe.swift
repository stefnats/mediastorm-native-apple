import Foundation

/// One source's health check with its tracks, as the Expo manual picker asks for them on a
/// long press (`useManualHealthChecks.checkHealth(result, probeForTracks: true)`).
struct SourceTrackProbe {
    /// Healthy (usenet) or cached (debrid).
    let playable: Bool
    let audio: [ProbedAudioTrack]
    let subtitles: [ProbedSubtitleTrack]
    /// Debrid: the server is still probing in the background; ask again shortly.
    let tracksLoading: Bool
    let error: String?
    var evidence: SourceFilterEvidence? = nil
}

extension APIClient {
    /// Usenet (and anything not debrid, as Expo treats it): `POST /api/usenet/health` with
    /// `probeForTracks`, which ffprobes the file synchronously once it is healthy. Debrid:
    /// `POST /api/debrid/cached` with `verifyUncached`, whose tracks may arrive on a later call
    /// (`tracksLoading`).
    static func sourceFilterProbeBody(_ result: SourceResult, context: SourceActionContext) -> [String: Any] {
        let isDebrid = result.serviceType.lowercased() == "debrid"
        var body: [String: Any] = ["result": result.raw, "profileId": context.profileID]
        if let snapshot = result.snapshotID { body["snapshotId"] = snapshot; body["sourceIndex"] = result.index }
        if isDebrid { body["quickOnly"] = false; body["verifyUncached"] = true }
        else { body["probeForTracks"] = true }
        return body
    }
    func probeTracks(_ result: SourceResult) async throws -> SourceTrackProbe {
        try await probeTracks(result, context: sourceContext())
    }
    func probeTracks(_ result: SourceResult, context: SourceActionContext) async throws -> SourceTrackProbe {
        guard result.filterSelection?.current != false else { throw CancellationError() }
        struct Response: Decodable {
            let healthy: Bool?
            let cached: Bool?
            let status: String?
            let errorMessage: String?
            let audioTracks: [ProbedAudioTrack]?
            let subtitleTracks: [ProbedSubtitleTrack]?
            let trackProbeError: String?
            let tracksLoading: Bool?
        }
        let isDebrid = result.serviceType.lowercased() == "debrid"
        let body = Self.sourceFilterProbeBody(result, context: context)
        let request = try Self.sourceFilterRequest(context, method: "POST", path: isDebrid ? "/api/debrid/cached" : "/api/usenet/health", body: body)
        let data = try await sourceFilterProbeData(request, context: context)
        let response = try decoder.decode(Response.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let evidence = SourceFilterEvidence.parse(object?["mediaEvidence"], candidate: result.candidateVersion)
        let playable = isDebrid ? (response.cached ?? false) : (response.healthy ?? false)
        var error = response.trackProbeError.flatMap { $0.isEmpty ? nil : $0 }
        if !playable {
            let status = (response.status ?? "").replacingOccurrences(of: "_", with: " ")
            error = response.errorMessage ?? (isDebrid ? "Not cached" : "Unhealthy\(status.isEmpty ? "" : " (\(status))")")
        }
        return SourceTrackProbe(playable: playable, audio: response.audioTracks ?? [],
                                subtitles: response.subtitleTracks ?? [],
                                tracksLoading: isDebrid && playable && (response.tracksLoading ?? false),
                                error: error, evidence: evidence)
    }
}
