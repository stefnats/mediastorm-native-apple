import Foundation

struct SpokenAudioResult: Decodable, Sendable {
    let status: String
    let reason: String?
    let requestedLanguage: String
    let detectedLanguage: String?
    let confidence: Double?
    let samples: Int
    let sourceVersion: String
    let audioTrackIndex: Int

    func validate(options: ReleaseReportOptions, track: Int) throws {
        guard ["unknown", "likely_match", "likely_mismatch"].contains(status),
              sourceVersion == options.sourceVersion, audioTrackIndex == track,
              !requestedLanguage.isEmpty,
              ManualTrackSelection.canonicalLanguage(requestedLanguage) == ManualTrackSelection.canonicalLanguage(options.audioLanguage),
              (0...2).contains(samples), confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
            throw APIError.notReady("The language check no longer matches this source and requested language")
        }
        if status != "unknown" {
            guard samples == 2, let confidence, confidence >= 0.90,
                  let detectedLanguage, let detected = ManualTrackSelection.canonicalLanguage(detectedLanguage),
                  let wanted = ManualTrackSelection.canonicalLanguage(requestedLanguage),
                  detected != "und", wanted != "und",
                  (status == "likely_match") == (detected == wanted) else {
                throw APIError.notReady("The language check has insufficient evidence")
            }
        }
    }
}

@MainActor
protocol SpokenAudioAPI: AnyObject {
    func isCurrent(_ context: SourceActionContext) -> Bool
    func checkSpokenAudio(_ id: String, options: ReleaseReportOptions, track: Int,
                          offset: Double, context: SourceActionContext) async throws -> SpokenAudioResult
}

extension APIClient: SpokenAudioAPI {
    static func spokenAudioRequest(_ id: String, options: ReleaseReportOptions, track: Int,
                                   offset: Double, context: SourceActionContext) throws -> URLRequest {
        guard !id.isEmpty, options.audioLanguageCheckAvailable == true,
              !options.sourceVersion.isEmpty, options.audioTracks?.contains(where: { $0.index == track }) == true,
              offset.isFinite, offset >= 0, offset <= 43_200 else {
            throw APIError.notReady("Choose a current audio track before checking spoken language")
        }
        return try context.request("POST", path: "/api/playback/prequeue/\(Self.segment(id))/audio-language",
            body: ["sourceVersion": options.sourceVersion, "audioTrackIndex": track, "startOffset": offset])
    }

    static func spokenAudioConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 110
        configuration.timeoutIntervalForResource = 110
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return configuration
    }

    func checkSpokenAudio(_ id: String, options: ReleaseReportOptions, track: Int,
                          offset: Double, context: SourceActionContext) async throws -> SpokenAudioResult {
        try requireSourceContext(context)
        var request = try Self.spokenAudioRequest(id, options: options, track: track, offset: offset, context: context)
        request.timeoutInterval = 110
        let session = URLSession(configuration: Self.spokenAudioConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.notReady("The language check was not confirmed") }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(HTTPFailure(status: response.statusCode, data: data, headers: response.allHeaderFields))
        }
        try requireSourceContext(context)
        let result = try decoder.decode(SpokenAudioResult.self, from: data)
        try result.validate(options: options, track: track)
        return result
    }
}
