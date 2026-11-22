import UIKit

/// Skip Intro / Skip Recap / Next Episode buttons, and starting the next episode.
extension PlayerViewController {
    // MARK: Skip segments

    /// Shows Skip Intro / Skip Recap / Next Episode in the transport bar while playback is
    /// inside a segment (on the software route, in its HUD).
    func updateSkipAction(at time: Double) {
        skipSegments.refresh(duration: engine.duration, chapters: engine.mediaChapters)
        let found = skipSegments.active(at: time)
        episodeAdvance?.observe(credits: found?.type == "outro", playing: engine.state == .playing,
            position: time, duration: engine.duration, failed: postPlayFailed || resumeWatch != nil)
        let segment = found == dismissedSegment ? nil : found
        guard segment != activeSegment else { return }
        activeSegment = segment
        refreshSkipAction()
    }

    private func refreshSkipAction() {
        let hadAction = !contextualActions.isEmpty
        defer {
            // Removing the button while it holds focus left AVKit with nothing focused, and the
            // remote no longer brought the transport bar up.
            if hadAction, contextualActions.isEmpty {
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
        }
        contextualActions = activeSegment.map { segment in
            [SkipSegments.action(
                for: segment, next: nextEpisode, countdown: nil,
                skip: { [weak self] end in
                    guard let self else { return }
                    Task { await self.engine.seek(to: min(end, self.engine.duration)) }
                },
                playNext: { [weak self] next in self?.playNext(next) }
            )]
        } ?? []
        // The software route has no AVKit chrome to show it; its HUD draws the same action.
        softwareHUD.setAction(contextualActions.first)
        #if os(iOS)
        mobileControls.setAction(contextualActions.first)
        #endif
    }

    /// Menu over the skip button hides AVKit's contextual-action presentation but leaves the
    /// action set, and while it stays set the remote can't bring the transport bar back up.
    /// Drop the action and don't offer it again for this segment.
    func dismissSkipActionIfMenu(_ presses: Set<UIPress>) {
        guard presses.contains(where: { $0.type == .menu }) else { return }
        dismissSkipActionIfMenu()
    }

    /// Menu on the software route's Skip capsule (the HUD routes it here).
    func dismissSkipActionIfMenu() {
        if episodeAdvance?.visible == true || activeSegment?.type == "outro" { episodeAdvance?.cancelCountdown() }
        guard let activeSegment, !contextualActions.isEmpty else { return }
        log.notice("skip button dismissed (\(activeSegment.type))")
        dismissedSegment = activeSegment
        self.activeSegment = nil
        refreshSkipAction()
    }

    // MARK: Up next

    func prefetchNextIfNear(_ time: Double) {
        guard !didPrefetchNext, let nextEpisode, episodeAdvance?.current == true, engine.duration > 0 else { return }
        guard time >= engine.duration * Self.prefetchFraction || activeSegment?.type == "outro" else { return }
        didPrefetchNext = true
        log.notice("prefetching \(nextEpisode.episode?.code ?? "?") at \(Int(time))s of \(Int(self.engine.duration))s")
        PlaybackCoordinator.shared.prefetch(nextEpisode, context: progressViewer)
    }

    func stopCountdown() { episodeAdvance?.cancelCountdown() }

    /// All controls share the same one-shot transition claim.
    func playNext(_ next: PlaybackRequest) {
        guard next.prequeueKey == nextEpisode?.prequeueKey else { return }
        episodeAdvance?.startNow()
    }
}
