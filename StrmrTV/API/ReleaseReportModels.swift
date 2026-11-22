import Foundation

struct ReleaseReportOptions: Decodable, Sendable {
    struct AudioTrack: Decodable, Sendable {
        let index: Int
        let language: String?
        let title: String?
        let codec: String?
    }
    let sourceVersion: String
    let releaseName: String
    let audioLanguage: String
    let audioTracks: [AudioTrack]?
    let selectedAudioTrack: Int
    let canShare: Bool
    let hasEpisode: Bool
    let canResetHistory: Bool
    var audioLanguageCheckAvailable: Bool? = nil

    func allows(_ reason: ReleaseReportReason) -> Bool {
        switch reason {
        case .wrongEpisode: hasEpisode
        case .missingLanguage: !audioLanguage.isEmpty && audioLanguage != "und"
        case .audioProblem: !(audioTracks ?? []).isEmpty
        default: true
        }
    }
}

enum ReleaseReportReason: String, CaseIterable, Identifiable {
    case wrongTitle = "wrong_title"
    case wrongEpisode = "wrong_episode"
    case missingLanguage = "missing_language"
    case audioProblem = "audio_problem"
    case fileProblem = "file_problem"
    case qualityProblem = "quality_problem"
    case deviceProblem = "device_problem"
    case sourceUnavailable = "source_unavailable"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .wrongTitle: String(localized: "Wrong title")
        case .wrongEpisode: String(localized: "Wrong episode")
        case .missingLanguage: String(localized: "Requested audio language is missing")
        case .audioProblem: String(localized: "A particular audio track is broken")
        case .fileProblem: String(localized: "Broken file")
        case .qualityProblem: String(localized: "Quality does not fit this profile")
        case .deviceProblem: String(localized: "This device cannot play it")
        case .sourceUnavailable: String(localized: "Source is temporarily unavailable")
        }
    }
    var permitsHistoryReset: Bool { self == .wrongTitle || self == .wrongEpisode }
}

struct ReleaseReportReply: Decodable, Sendable {
    struct Report: Decodable, Sendable { let id: String }
    struct Replacement: Decodable, Sendable {
        let prequeueId: String
        let status: String
    }
    let report: Report?
    let replacement: Replacement?
    let resumePosition: Double?
    let historyReset: Bool?
    let historyResetError: String?
    let retryError: String?

    var partialFailure: String? {
        if historyResetError != nil || historyReset == false {
            return String(localized: "The report was saved, but history was not reset. No alternative was started.")
        }
        if retryError != nil { return String(localized: "The report was saved, but an alternative could not be prepared.") }
        return nil
    }
}

struct ReleaseReportSubmission {
    let reason: ReleaseReportReason?
    let retry: Bool
    let resetHistory: Bool
    let audioTrackIndex: Int?
    let position: Double

    func body(options: ReleaseReportOptions, clientID: String) throws -> [String: Any] {
        guard !options.sourceVersion.isEmpty, position.isFinite, position >= 0 else {
            throw APIError.notReady("Reopen the source dialog before trying again")
        }
        if let reason, !options.allows(reason) { throw APIError.notReady("This reason is unavailable for this source") }
        guard !resetHistory || reason?.permitsHistoryReset == true && options.canResetHistory else {
            throw APIError.notReady("History reset requires a wrong-content report")
        }
        var body: [String: Any] = ["sourceVersion": options.sourceVersion, "clientId": clientID,
                                   "retry": retry, "resetHistory": resetHistory, "skipHLS": true,
                                   "startOffset": reason?.permitsHistoryReset == true ? 0.0 : position]
        if let reason { body["reason"] = reason.rawValue }
        if reason == .missingLanguage { body["audioLanguage"] = options.audioLanguage }
        if reason == .audioProblem {
            guard let index = audioTrackIndex, options.audioTracks?.contains(where: { $0.index == index }) == true else {
                throw APIError.notReady("Choose an audio track from this source")
            }
            body["audioTrackIndex"] = index
        }
        return body
    }
}
