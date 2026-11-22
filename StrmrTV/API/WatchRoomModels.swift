import Foundation

enum WatchRoomError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Current room or playback data is unavailable. Read the room explicitly; no action was replayed." }
}

struct WatchRoomCapabilities: Codable, Equatable {
    let nativePlayback: Bool
    let stateSync: Bool
    let protocolVersion: Int
    static let native = Self(nativePlayback:true,stateSync:true,protocolVersion:1)
}

struct WatchRoomMember: Decodable, Equatable, Identifiable {
    let profileId: String
    let name: String
    let clientId: String?
    let isCreator: Bool
    let ready: Bool
    let buffering: Bool
    let joined: Bool
    let present: Bool
    let capabilities: WatchRoomCapabilities
    var id: String { profileId }
}

struct WatchRoom: Decodable, Equatable, Identifiable {
    let id: String
    let creatorProfileId: String
    let creatorName: String
    let title: String
    let mediaType: String
    let itemId: String
    let posterUrl: String?
    let backdropUrl: String?
    let params: [String:String]
    let status: String
    let waitingForReady: Bool
    let position: Double
    let duration: Double
    let revision: Int64
    let updatedBy: String?
    let anchorUpdatedAt: String
    let expiresAt: String
    let members: [WatchRoomMember]
    func validate() throws {
        guard UUID(uuidString:id) != nil, !creatorProfileId.isEmpty, !title.isEmpty, title.utf8.count <= 4096,
              ["lobby","playing","paused","ended"].contains(status), revision >= 0,
              position.isFinite, position >= 0, duration.isFinite, duration >= 0,
              duration == 0 || position <= duration, RecordingCapture.date(anchorUpdatedAt) != nil,
              RecordingCapture.date(expiresAt) != nil, members.count <= 256,
              Set(members.map(\.profileId)).count == members.count else { throw WatchRoomError.unavailable }
        for member in members {
            guard !member.profileId.isEmpty, !member.joined || member.clientId?.isEmpty == false else { throw WatchRoomError.unavailable }
        }
        _ = try WatchRoomTarget(room:self)
    }
    func member(_ context: SourceActionContext) -> WatchRoomMember? { members.first { $0.profileId == context.profileID } }
}

struct WatchRoomAccountInvite: Decodable, Equatable, Identifiable {
    let id: String
    let roomId: String
    let inviteeUsername: String?
    let status: String
    let creatorName: String?
    let title: String?
    let expiresAt: String
    func validate() throws {
        guard UUID(uuidString:id) != nil, UUID(uuidString:roomId) != nil,
              ["pending","accepted","declined","revoked"].contains(status), RecordingCapture.date(expiresAt) != nil else { throw WatchRoomError.unavailable }
    }
}

/// Catalogue coordinates only; room parameters never contain a resource, media
/// URL, profile selector or someone else's credentials.
struct WatchRoomTarget: Equatable {
    let title: DetailsTarget
    let season: Int?
    let episode: Int?
    let episodeName: String?
    static func == (a: Self, b: Self) -> Bool {
        a.title.titleID == b.title.titleID && a.title.isMovie == b.title.isMovie && a.title.name == b.title.name &&
            a.title.tmdbID == b.title.tmdbID && a.title.imdbID == b.title.imdbID && a.title.tvdbID == b.title.tvdbID &&
            a.title.year == b.title.year && a.season == b.season && a.episode == b.episode
    }
    var itemID: String { title.titleID + (season.map { String(format:":S%02dE%02d",$0,episode ?? 0) } ?? "") }
    var playback: PlaybackRequest {
        PlaybackRequest(title:title,episode:season.map { .init(season:$0,episode:episode!,absolute:nil,name:episodeName,itemID:itemID) },start:nil)
    }
    init(title: DetailsTarget, episode: PlaybackRequest.EpisodeInfo?) throws {
        guard title.hasCatalogIDs, !title.titleID.isEmpty, title.titleID.utf8.count <= 128, !title.name.isEmpty,
              title.titleID.range(of:#"^(tmdb|tvdb|imdb):"#,options:.regularExpression) != nil,
              title.isMovie == (episode == nil) else { throw WatchRoomError.unavailable }
        if let episode {
            guard (0...99999).contains(episode.season), (1...99999).contains(episode.episode),
                  episode.numbering?.ordering == nil || episode.numbering?.ordering == "" || episode.numbering?.ordering == "default" || episode.numbering?.ordering == "official" else { throw WatchRoomError.unavailable }
        }
        self.title = title; season = episode?.season; self.episode = episode?.episode; episodeName = episode?.name
    }
    init(room: WatchRoom) throws {
        let p = room.params
        let keys: Set<String> = ["titleId","titleName","mediaType","imdbId","tmdbId","tvdbId","year","seasonNumber","episodeNumber","episodeName"]
        guard Set(p.keys).isSubset(of:keys), p.values.allSatisfy({$0.utf8.count <= 4096}),
              let id = p["titleId"], !id.isEmpty, ["movie","series","episode"].contains(room.mediaType) else { throw WatchRoomError.unavailable }
        let movie = room.mediaType == "movie"
        guard p["mediaType"] == (movie ? "movie" : "series") else { throw WatchRoomError.unavailable }
        var number: PlaybackRequest.EpisodeInfo?
        if !movie {
            guard let s = p["seasonNumber"], let e = p["episodeNumber"], let season = Int(s), let episode = Int(e),
                  String(season) == s, String(episode) == e else { throw WatchRoomError.unavailable }
            number = .init(season:season,episode:episode,absolute:nil,name:p["episodeName"],itemID:room.itemId)
        } else if p["seasonNumber"] != nil || p["episodeNumber"] != nil { throw WatchRoomError.unavailable }
        let target = DetailsTarget(titleID:id,name:room.title,isMovie:movie,year:p["year"].flatMap(Int.init),
            tmdbID:p["tmdbId"],imdbID:p["imdbId"],tvdbID:p["tvdbId"],posterURL:room.posterUrl,
            textPosterURL:nil,backdropURL:room.backdropUrl,logoURL:nil,overview:nil)
        try self.init(title:target,episode:number)
        guard room.itemId == itemID else { throw WatchRoomError.unavailable }
    }
    var params: [String:String] {
        var values = ["titleId":title.titleID,"titleName":title.name,"mediaType":title.isMovie ? "movie" : "series"]
        values["imdbId"] = title.imdbID; values["tmdbId"] = title.tmdbID; values["tvdbId"] = title.tvdbID
        values["year"] = title.year.map(String.init)
        values["seasonNumber"] = season.map(String.init); values["episodeNumber"] = episode.map(String.init); values["episodeName"] = episodeName
        return values
    }
}

struct WatchRoomObservation {
    let room: WatchRoom
    let received: ContinuousClock.Instant
    init(_ room: WatchRoom, received: ContinuousClock.Instant = .now) { self.room = room; self.received = received }
    func position(now: ContinuousClock.Instant = .now) -> Double {
        let elapsed = room.status == "playing" && !room.waitingForReady ? max(0,RecordingWire.milliseconds(received.duration(to:now))/1000) : 0
        // The Go DTO already includes time since anchorUpdatedAt. Only advance
        // from this local receipt, never add the server anchor a second time.
        return room.position + elapsed
    }
}
