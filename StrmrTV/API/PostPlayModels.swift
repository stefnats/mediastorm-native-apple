import Foundation

struct PostPlayStamp {
    let orderingKnown: Bool
    let lifecycle: String?
    let upcoming: Episode?
    let seasons: [Season]
    static func capture(title: Title?, seasons: [Season], selected: Episode?) -> Self? {
        guard let title else { return nil }
        if title.isMovie { return Self(orderingKnown: true, lifecycle: nil, upcoming: nil, seasons: []) }
        guard let selected else { return nil }
        let regular = seasons.filter { $0.number > 0 }.sorted { $0.number < $1.number }.flatMap(\.episodes)
        guard let index = regular.firstIndex(where: { $0.id == selected.id && $0.seasonNumber == selected.seasonNumber && $0.episodeNumber == selected.episodeNumber && $0.numbering == selected.numbering }) else {
            return Self(orderingKnown: false, lifecycle: title.lifecycleStatus, upcoming: nil, seasons: [])
        }
        let upcoming = regular.dropFirst(index + 1).first { ReleaseBadge.forEpisode(airDate: $0.airedDate) != nil }
        return Self(orderingKnown: true, lifecycle: title.lifecycleStatus, upcoming: upcoming, seasons: seasons)
    }
    func advancing(to next: PlaybackRequest.EpisodeInfo) -> Self {
        let regular = seasons.filter { $0.number > 0 }.sorted { $0.number < $1.number }.flatMap(\.episodes)
        guard let index = regular.firstIndex(where: { $0.seasonNumber == next.season && $0.episodeNumber == next.episode && $0.numbering == next.numbering && (next.itemID == nil || $0.itemId == next.itemID) }) else {
            return Self(orderingKnown: false, lifecycle: lifecycle, upcoming: nil, seasons: seasons)
        }
        return Self(orderingKnown: orderingKnown, lifecycle: lifecycle, upcoming: regular.dropFirst(index + 1).first { ReleaseBadge.forEpisode(airDate: $0.airedDate) != nil }, seasons: seasons)
    }
    var seriesEnded: Bool { orderingKnown && ["ended", "canceled", "cancelled"].contains(lifecycle?.lowercased() ?? "") && upcoming == nil }
}

struct PostPlayCompletion: @unchecked Sendable {
    let context: SourceActionContext
    let itemID: String
    let mediaType: String
}

/// Ephemeral original-player delivery, never a server completion grant.
@MainActor
final class PostPlayOffer: Identifiable {
    let id: UUID
    let request: PlaybackRequest
    let context: SourceActionContext
    let completion: PostPlayCompletion?
    let failure: String?
    init(id: UUID, request: PlaybackRequest, context: SourceActionContext, completion: PostPlayCompletion?, failure: String? = nil) {
        self.id = id; self.request = request; self.context = context; self.completion = completion; self.failure = failure
    }
}

struct PostPlayContextReply: Decodable {
    let title: Title
    let rating: PersonalTitleRating
    let ratingScope: String
    let completion: String
    func validate(_ target: DetailsTarget) throws {
        guard ReminderChoices.sameTitle(target, title), title.mediaType == (target.isMovie ? "movie" : "series"),
              ratingScope == title.mediaType, completion == (target.isMovie ? "movie" : "episode") else { throw PostPlayFailure.invalid }
    }
}
struct PostPlaySuggestionsReply: Decodable {
    let items: [TrendingItem]
    let total: Int
    let source: String
    let rating: PersonalTitleRating
    let ratingScope: String
    func validate(target: DetailsTarget, rating: PersonalTitleRating) throws {
        guard self.rating == rating, ratingScope == (target.isMovie ? "movie" : "series"),
              ["personalized", "saved_choices", "unavailable"].contains(source), total == items.count, (0...12).contains(total),
              source != "unavailable" || items.isEmpty else { throw PostPlayFailure.invalid }
        var seen = Set<String>(), counts: [String: Int] = [:]
        for row in items {
            let title = row.title
            guard PersonalTasteWire.valid(title), ["movie", "series"].contains(title.mediaType),
                  !ReminderChoices.sameTitle(target, title), title.personalRating != "dislike",
                  seen.insert(title.mediaType + ":" + title.id).inserted else { throw PostPlayFailure.invalid }
            counts[title.mediaType, default: 0] += 1
            guard counts[title.mediaType, default: 0] <= 6 else { throw PostPlayFailure.invalid }
        }
    }
}

final class PostPlaySuggestion: Identifiable {
    let title: Title
    var id: String { title.mediaType + ":" + title.id }
    init(_ title: Title) { self.title = title }
}

enum PostPlayFailure: LocalizedError {
    case invalid, completion, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: "The completed title or suggestions could not be confirmed. Reload this view."
        case .completion: "The final playback acknowledgement could not be confirmed. No personal rating was changed."
        case .unavailable: "Suggestions are unavailable. Retry when ready or close this view."
        }
    }
}
