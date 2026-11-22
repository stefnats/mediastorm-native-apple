import Foundation

struct ReminderSubject {
    let target: DetailsTarget
    let title: Title
    let seasons: [Season]

    init(target: DetailsTarget, title: Title, seasons: [Season]) throws {
        guard ReminderChoices.sameTitle(target, title), ReminderChoices.catalogued(title) else { throw ReminderFailure.invalid }
        self.target = target; self.title = title; self.seasons = seasons
    }
    var choices: [ReminderChoice] {
        let id = title.id
        if title.isMovie {
            return ["digital", "physical", "theatrical"].map {
                ReminderChoice(contentId: id, contentType: "movie", eventKind: "release", releaseType: $0, episode: nil)
            } + [ReminderChoice(contentId: id, contentType: "movie", eventKind: "matching_source", releaseType: nil, episode: nil)]
        }
        var choices = [ReminderChoice(contentId: id, contentType: "series", eventKind: "new_episode", releaseType: nil, episode: nil)]
        let references = Array(Set(seasons.flatMap(\.episodes).compactMap(ReminderChoices.official)))
            .sorted { ($0.seasonNumber, $0.episodeNumber, $0.episodeId) < ($1.seasonNumber, $1.episodeNumber, $1.episodeId) }
        let byID = Dictionary(grouping: references) { $0.numbering.seriesId + ":" + $0.episodeId }
        let byCoordinate = Dictionary(grouping: references) { $0.numbering.seriesId + ":\($0.seasonNumber):\($0.episodeNumber)" }
        for reference in references {
            guard byID[reference.numbering.seriesId + ":" + reference.episodeId]?.count == 1,
                  byCoordinate[reference.numbering.seriesId + ":\(reference.seasonNumber):\(reference.episodeNumber)"]?.count == 1 else { continue }
            choices.append(ReminderChoice(contentId: id, contentType: "series", eventKind: "matching_source", releaseType: nil, episode: reference))
        }
        return choices
    }
}

struct ReminderChoice: Equatable, Identifiable {
    let contentId: String
    let contentType: String
    let eventKind: String
    let releaseType: String?
    let episode: ReminderEpisode?
    var id: String { eventKind + ":" + (releaseType ?? "") + ":" + (episode?.episodeId ?? "") + ":" + (episode?.numbering.seriesId ?? "") + ":" + String(episode?.seasonNumber ?? 0) + ":" + String(episode?.episodeNumber ?? 0) }
    var label: String {
        switch eventKind {
        case "release": String(localized: "Announced \(releaseType ?? "") release date")
        case "new_episode": String(localized: "New episode metadata for this series")
        default: episode.map { String(localized: "Matching source candidate for S\($0.seasonNumber)E\($0.episodeNumber)") }
            ?? String(localized: "A matching source candidate")
        }
    }
    func body() throws -> [String: Any] {
        guard ReminderChoices.contentID(contentId), ["movie", "series"].contains(contentType) else { throw ReminderFailure.invalid }
        switch eventKind {
        case "release": guard contentType == "movie", episode == nil, ["digital", "physical", "theatrical"].contains(releaseType ?? "") else { throw ReminderFailure.invalid }
        case "new_episode": guard contentType == "series", episode == nil, releaseType == nil else { throw ReminderFailure.invalid }
        case "matching_source": guard releaseType == nil, contentType == "movie" ? episode == nil : episode.map(ReminderChoices.official) == true else { throw ReminderFailure.invalid }
        default: throw ReminderFailure.invalid
        }
        var result: [String: Any] = ["contentId": contentId, "contentType": contentType, "eventKind": eventKind]
        if let releaseType { result["releaseType"] = releaseType }
        if let episode {
            result["episode"] = ["episodeId": episode.episodeId, "numbering": ["seriesId": episode.numbering.seriesId, "ordering": "official"],
                "seasonNumber": episode.seasonNumber, "episodeNumber": episode.episodeNumber]
        }
        return result
    }
    func confirms(_ item: Reminder, requested: String?, subject: ReminderSubject) -> Bool {
        requested == contentId && item.contentType == contentType && item.eventKind == eventKind && item.releaseType == releaseType &&
            item.episode == episode && item.createdOnCurrentDevice && ReminderChoices.valid(item) && ReminderChoices.sameTitle(DetailsTarget(subject.title), item.title)
    }
}

enum ReminderFailure: LocalizedError {
    case invalid, unsupported, changed
    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "The reminder data could not be confirmed. Refresh before trying again.")
        case .unsupported: String(localized: "Update the server to use reminders and inbox for this adult profile.")
        case .changed: String(localized: "The profile or connection changed. Reopen reminders.")
        }
    }
}

enum ReminderChoices {
    static func identifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
    }
    static func contentID(_ value: String) -> Bool { !value.isEmpty && value.count <= 128 && value.trimmingCharacters(in: .whitespacesAndNewlines) == value && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    static func catalogued(_ title: Title) -> Bool {
        contentID(title.id) && !title.name.isEmpty && ["movie", "series"].contains(title.mediaType) &&
            (title.tmdbId.map { $0 > 0 } == true || title.tvdbId.map { $0 > 0 } == true || title.imdbId?.range(of: #"^tt[0-9]+$"#, options: .regularExpression) != nil ||
             title.id.range(of: #"^(?:tmdb:(?:movie|series|tv):[1-9][0-9]*|tvdb:(?:(?:series|movie):)?[1-9][0-9]*|tt[0-9]+)$"#, options: .regularExpression) != nil)
    }
    static func sameTitle(_ target: DetailsTarget, _ title: Title) -> Bool {
        guard target.isMovie == title.isMovie else { return false }
        if let expected = target.tmdbID.flatMap(Int.init), expected > 0, let actual = title.tmdbId, actual > 0, expected != actual { return false }
        if let expected = target.tvdbID.flatMap(Int.init), expected > 0, let actual = title.tvdbId, actual > 0, expected != actual { return false }
        if let expected = target.imdbID, !expected.isEmpty, let actual = title.imdbId, !actual.isEmpty, expected != actual { return false }
        return target.titleID == title.id || target.tmdbID.flatMap(Int.init).map { $0 > 0 && $0 == title.tmdbId } == true ||
            target.tvdbID.flatMap(Int.init).map { $0 > 0 && $0 == title.tvdbId } == true ||
            target.imdbID.map { $0.hasPrefix("tt") && $0 == title.imdbId } == true
    }
    static func official(_ episode: Episode) -> ReminderEpisode? {
        guard let numbering = episode.numbering else { return nil }
        let result = ReminderEpisode(episodeId: episode.id, numbering: EpisodeNumbering(seriesId: numbering.seriesId, ordering: "official"),
            seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber)
        return (numbering.ordering == nil || numbering.ordering == "" || numbering.ordering == "official") && official(result) ? result : nil
    }
    static func official(_ episode: ReminderEpisode) -> Bool {
        episode.episodeId.count <= 256 && !episode.episodeId.isEmpty && episode.numbering.ordering == "official" &&
            episode.numbering.seriesId.range(of: #"^(?:tmdb:(?:series|tv):[1-9][0-9]*|tvdb:(?:series:)?[1-9][0-9]*)$"#, options: .regularExpression) != nil &&
            (0...10_000).contains(episode.seasonNumber) && (1...100_000).contains(episode.episodeNumber)
    }
    static func details(_ id: String, kind: String, title: Title) -> DetailsTarget? {
        guard id == title.id, kind == title.mediaType, catalogued(title) else { return nil }
        return DetailsTarget(title)
    }
    static func valid(_ item: Reminder) -> Bool {
        identifier(item.id) && details(item.contentId, kind: item.contentType, title: item.title) != nil &&
            ["waiting", "triggered"].contains(item.state) && RecordingCapture.date(item.createdAt) != nil && instant(item.lastObservedAt) && validKind(item.eventKind, kind: item.contentType, release: item.releaseType, episode: item.episode)
    }
    static func valid(_ item: ReminderEvent) -> Bool {
        identifier(item.id) && identifier(item.reminderId) && details(item.contentId, kind: item.contentType, title: item.title) != nil &&
            RecordingCapture.date(item.occurredAt) != nil && instant(item.readAt) && instant(item.dismissedAt) && validKind(item.eventKind, kind: item.contentType, release: item.releaseType, episode: item.episode, event: true) &&
            (item.eventKind == "matching_source" ? item.candidateOnly : !item.candidateOnly)
    }
    private static func instant(_ raw: String?) -> Bool { raw == nil || raw.map { $0.count <= 64 && RecordingCapture.date($0) != nil } == true }
    private static func validKind(_ value: String, kind: String, release: String?, episode: ReminderEpisode?, event: Bool = false) -> Bool {
        switch value {
        case "release": kind == "movie" && episode == nil && ["digital", "physical", "theatrical"].contains(release ?? "")
        case "new_episode": kind == "series" && release == nil && (event ? episode.map(official) == true : episode == nil)
        case "matching_source": release == nil && (kind == "movie" ? episode == nil : episode.map(official) == true)
        default: false
        }
    }
}

/// A browsing destination only. Root's actual detail router consumes this flag;
/// it is never a playback, source or authorization grant.
struct ReminderTitleDestination {
    let target: DetailsTarget
    let context: SourceActionContext
    let automaticallyPrewarm = false
}
