import Foundation

struct ReminderEpisode: Codable, Hashable {
    let episodeId: String
    let numbering: EpisodeNumbering
    let seasonNumber: Int
    let episodeNumber: Int
}

struct Reminder: Decodable, Identifiable, Hashable {
    let id: String
    let contentId: String
    let contentType: String
    let eventKind: String
    let title: Title
    let releaseType: String?
    let episode: ReminderEpisode?
    let state: String
    let createdOnCurrentDevice: Bool
    let createdAt: String
    let lastObservedAt: String?

    var description: String { ReminderText.description(eventKind, release: releaseType, episode: episode) }
    var deviceLabel: String? {
        guard eventKind == "matching_source" else { return nil }
        return createdOnCurrentDevice ? String(localized: "Source checks for this device") : String(localized: "Source checks for another device")
    }
}

struct ReminderEvent: Decodable, Identifiable, Hashable {
    let id: String
    let reminderId: String
    let eventKind: String
    let contentId: String
    let contentType: String
    let title: Title
    let episode: ReminderEpisode?
    let releaseType: String?
    let occurredAt: String
    let readAt: String?
    let dismissedAt: String?
    let candidateOnly: Bool
    var description: String { ReminderText.description(eventKind, release: releaseType, episode: episode) }
}

struct ReminderList: Decodable {
    let remindersSupported: Bool?
    let monitoring: String?
    let items: [Reminder]
}
struct ReminderInbox: Decodable {
    let remindersSupported: Bool?
    let monitoring: String?
    let items: [ReminderEvent]
    let nextCursor: String?
}
struct ReminderCreated: Decodable {
    struct Candidate: Decodable { let state: String; let reason: String? }
    let remindersSupported: Bool?
    let monitoring: String?
    let item: Reminder?
    let requestedContentId: String?
    let currentCandidate: Candidate?
}
struct ReminderUpdated: Decodable {
    let remindersSupported: Bool?
    let item: ReminderEvent?
}

enum ReminderText {
    static let passive = String(localized: "Updates when this title is checked in the app. No extra searches or external notifications.")
    static func description(_ kind: String, release: String?, episode: ReminderEpisode?) -> String {
        switch kind {
        case "release":
            let type = ["digital", "physical", "theatrical"].contains(release ?? "") ? release! : "announced"
            return String(localized: "Announced \(type) release date. Playback availability is not confirmed.")
        case "new_episode": return String(localized: "New episode metadata was observed. A playable stream is not confirmed.")
        case "matching_source":
            let code = episode.map { "S\($0.seasonNumber)E\($0.episodeNumber): " } ?? ""
            return String(localized: "\(code)A matching source candidate, not a playback guarantee.")
        default: return String(localized: "An update was recorded for this title.")
        }
    }
    static func recorded(_ raw: String) -> String? {
        guard let date = RecordingCapture.date(raw) else { return nil }
        return String(localized: "Recorded \(date.formatted(date: .abbreviated, time: .shortened))")
    }
}
