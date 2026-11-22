import Foundation

enum ReleaseAlternativeStart: String, CaseIterable, Identifiable {
    case beginning, current, rewindTen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .beginning: String(localized: "Beginning")
        case .current: String(localized: "Current position")
        case .rewindTen: String(localized: "Current position minus 10 seconds")
        }
    }

    func position(current: Double?, wrongContent: Bool) throws -> Double {
        if wrongContent || self == .beginning { return 0 }
        guard let current, current.isFinite, current >= 0 else {
            throw APIError.notReady("The current playback position is unavailable. Choose Beginning.")
        }
        return self == .rewindTen ? max(0, current - 10) : current
    }
}

enum ReleaseAlternativeHandoff {
    static func validate(_ ready: PrequeueStatus, id: String, request: PlaybackRequest) throws {
        guard request.allowsExternalSourceSelection, ready.prequeueId == id,
              ready.status == "ready", ready.streamPath?.isEmpty == false else {
            throw APIError.notReady("The alternative is not ready. The current player was kept open.")
        }
        if let episode = request.episode {
            guard ready.targetEpisode?.seasonNumber == episode.season,
                  ready.targetEpisode?.episodeNumber == episode.episode else {
                throw APIError.notReady("The alternative is for a different episode")
            }
        } else if ready.targetEpisode != nil {
            throw APIError.notReady("The alternative is for a different episode")
        }
    }
}
