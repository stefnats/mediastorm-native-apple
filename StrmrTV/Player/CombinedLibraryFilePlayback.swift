import Foundation

/// Membership is presentation data, not a chapter map or permission. A confirmed
/// combined file uses the existing unmatched-file playback/progress path.
enum CombinedLibraryFilePlayback {
    static func validate(_ playback: LibraryPlaybackInfo, itemID: String) throws {
        guard playback.itemId == itemID, !playback.streamPath.isEmpty,
              playback.progressScope == "file", let members = playback.combinedEpisodes,
              (2...1000).contains(members.count), Set(members).count == members.count,
              members.allSatisfy({ $0.seasonNumber >= 0 && $0.episodeNumber > 0 }) else {
            throw APIError.notReady("The combined file's current membership is unavailable. Reload its version.")
        }
    }

    static func request(_ original: PlaybackRequest, version: LibraryVersion,
                        playback: LibraryPlaybackInfo) throws -> PlaybackRequest {
        try validate(playback, itemID: version.id)
        // This is an unmatched file presentation, not a synthetic catalogue ID.
        // Actual progress is keyed by streamPath by PlaybackRequest.progressReport.
        let group = LibraryGroup(id: playback.itemId, groupType: "file", libraryType: "other",
            title: playback.displayName ?? playback.fileName ?? version.releaseName,
            overview: nil, year: nil, tmdbId: nil, tvdbId: nil, imdbId: nil,
            poster: nil, textPoster: nil, backdrop: nil, textBackdrop: nil,
            items: [version.item], seasons: nil)
        let target = DetailsTarget(unmatched: group)
        var request = PlaybackRequest(title: target, episode: nil, start: nil,
                                      following: [], artwork: .init())
        request.libraryVersion = version
        request.speed = original.speed
        #if DEBUG
        request.reportsProgress = original.reportsProgress
        #endif
        return request
    }
}
