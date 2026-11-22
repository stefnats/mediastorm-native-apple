import Foundation

/// The two-second genuine-end tolerance follows the existing native policy.
/// A stopped transport, early EOF or a manually closed player is not completion.
@MainActor
final class PostPlayEndPolicy {
    private(set) var claimed = false
    func claim(request: PlaybackRequest, position: Double, duration: Double, live: Bool,
               failed: Bool, discarded: Bool, offline: Bool, reportsProgress: Bool) -> Bool {
        guard !claimed, reportsProgress, !live, !failed, !discarded, !offline,
              !request.fileOnlyPlayback, !request.isUnmatchedLibraryFile, request.nextEpisode == nil,
              request.title.isMovie ? request.episode == nil : request.isEpisode,
              request.title.hasCatalogIDs, !request.isEpisode || request.postPlayStamp?.orderingKnown == true,
              position.isFinite, duration.isFinite, duration > 0, position > 0,
              position >= max(0, duration - 2) else { return false }
        claimed = true; return true
    }
}

@MainActor
enum PostPlayCompletionPipeline {
    static func offer(after finalReport: Task<Result<PostPlayCompletion, Error>, Never>, request: PlaybackRequest,
                      original: SourceActionContext, id: UUID,
                      current: (SourceActionContext) -> Bool) async -> PostPlayOffer? {
        let result = await finalReport.value
        guard !Task.isCancelled else { return nil }
        switch result {
        case let .success(completed):
            guard current(completed.context) else { return nil }
            return PostPlayOffer(id: id, request: request, context: completed.context, completion: completed)
        case .failure:
            guard current(original) else { return nil }
            return PostPlayOffer(id: id, request: request, context: original, completion: nil, failure: PostPlayFailure.completion.localizedDescription)
        }
    }
}

extension PlayerViewController {
    /// Returns true once this old player owns its completion workflow. Duplicate
    /// ended events stay handled while the final acknowledgement is pending.
    func offerPostPlay() -> Bool {
        if postPlayEnd.claimed { return true }
        guard progressViewer.sameViewer(as: APIClient.shared.sourceContext()), PlaybackCoordinator.shared.resolving == nil else { return false }
#if DEBUG
        let reports = request.reportsProgress
#else
        let reports = true
#endif
        guard postPlayEnd.claim(request: request, position: lastKnownPosition, duration: lastKnownDuration,
            live: engine.isLive, failed: postPlayFailed || autoSwitchState.failureOnGiveUp != nil || autoSwitchState.isSwitching,
            discarded: isAdvancing || reportedWrongContent || !progressWriter.accepting || isExitingToDetails || didFinish || resumeWatch != nil || isBeingDismissed || presentedViewController != nil,
            offline: playsDownload, reportsProgress: reports) else { return false }
        let id = UUID(), context = progressViewer, request = request
        let operation = PlaybackCoordinator.shared.beginPostPlay(id)
        progressTimer?.invalidate(); progressTimer = nil; stopAutoSwitchWatch(); stopCountdown()
        engine.pause()
        let body = request.progressReport(position: lastKnownPosition, duration: lastKnownDuration, paused: true,
            ended: true, sourcePath: streamPath, stream: streamHealth())
        let finalReport = progressWriter.beginCompletion(body)
        postPlayTask = Task { [weak self] in
            guard let self else { return }
            let result = await PostPlayCompletionPipeline.offer(after: finalReport, request: request, original: context, id: id,
                current: { APIClient.shared.isCurrent($0) })
            guard !Task.isCancelled, !didFinish else { return }
            guard let offer = result else { dismissOwnedPostPlay(operation); return }
            guard !didFinish, PlaybackCoordinator.shared.postPlayOperationCurrent(operation) else { return }
            dismiss(animated: true) {
                PlaybackCoordinator.shared.publishPostPlay(offer, operation: operation)
            }
        }
        return true
    }
    private func dismissOwnedPostPlay(_ operation: UUID) {
        guard !didFinish, !isBeingDismissed, PlaybackCoordinator.shared.postPlayOperationCurrent(operation) else { return }
        dismiss(animated: true)
    }

}
