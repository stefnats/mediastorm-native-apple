import Foundation

extension PlaybackCoordinator {
    /// Manual library choice. Combined episodes require explicit from-beginning
    /// consent and the existing unmatched-file progress identity.
    func playLibrary(_ request: PlaybackRequest, version: LibraryVersion, playback known: LibraryPlaybackInfo? = nil) {
        var request = request
        request.libraryVersion = version
        let api = APIClient.shared
        let original = api.sourceContext()
        begin(request, stage: String(localized: "Preparing…")) { [self] in
            var playback = if let known { known } else { try await api.libraryPlayback(itemID: version.item.id) }
            guard original.sameViewer(as: api.sourceContext()) else {
                throw APIError.notReady("Profile or connection changed during library preparation")
            }
            let context = api.sourceContext()
            let combined = playback.isCombinedFile || version.item.isCombinedFile
            if combined {
                try CombinedLibraryFilePlayback.validate(playback, itemID: version.id)
                guard await confirmCombinedLibraryFile(playback) else { throw CancellationError() }
                try api.requireSourceContext(context)
                // The prompt does not extend a source, cache TTL or permission.
                // Re-read actual current access/data before constructing the player.
                let current = try await api.libraryPlayback(itemID: version.id)
                try api.requireSourceContext(context)
                guard current == playback else {
                    throw APIError.notReady("The combined file changed. Reopen its version before playing.")
                }
                playback = current
            }
            await TrackSettingsStore.shared.loadProfileValues()
            guard original.sameViewer(as: api.sourceContext()) else {
                throw APIError.notReady("Profile or connection changed during library preparation")
            }
            if combined { try api.requireSourceContext(context) }
            var source = SourceSwitch.Current(releaseName: version.releaseName,
                streamPath: playback.streamPath, origin: version.origin)
            if combined {
                source.combinedFile = playback
                source.viewerContext = context
            }
            return (playback.streamPath, TrackPreferences.library, source)
        }
    }
}
