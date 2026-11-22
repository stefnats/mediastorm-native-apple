import SwiftUI

/// Applied inside the actual per-profile roots, under their environment stores.
/// The existing deferred browsing obligation is read, never consumed or minted.
struct PostPlayPresentation: ViewModifier {
    @ObservedObject private var playback = PlaybackCoordinator.shared
    @ObservedObject private var session = AppSession.shared
    @State private var retryPresented: EpisodeAdvanceFailure?
    @State private var retryQueued: EpisodeAdvanceFailure?
    @State private var presented: UUID?
    @State private var queued: (request: PlaybackRequest, context: SourceActionContext, operation: UUID)?
    private var eligible: Binding<PostPlayOffer?> {
        Binding(get: {
            guard session.phase == .ready, !session.protectedBrowsingBlocked, !session.resumeGate.blocked,
                  !session.hasProtectedPlaybackPresentation, let offer = playback.postPlay,
                  APIClient.shared.isCurrent(offer.context) else { return nil }
            return offer
        }, set: { next in
            if next == nil, let id = presented { playback.dismissPostPlay(id) }
        })
    }
    private var eligibleRetry: Binding<EpisodeAdvanceFailure?> {
        Binding(get: {
            guard session.phase == .ready, !session.protectedBrowsingBlocked, !session.resumeGate.blocked,
                  !session.hasProtectedPlaybackPresentation, let failure = playback.episodeRetry,
                  APIClient.shared.isCurrent(failure.context) else { return nil }
            return failure
        }, set: { next in
            if next == nil, let old = retryPresented { playback.dismissEpisodeRetry(old, queuedRetry: retryQueued?.id == old.id) }
        })
    }
    func body(content: Content) -> some View {
        content.fullScreenCover(item: eligible, onDismiss: finishNavigation) { offer in
            PostPlayScene(offer: offer, onClose: { playback.dismissPostPlay(offer.id) }, onPlay: { request in
                guard APIClient.shared.isCurrent(offer.context), playback.postPlayOperationCurrent(offer.id) else { return }
                queued = (request, offer.context, offer.id); playback.dismissPostPlay(offer.id)
            })
            .onAppear { presented = offer.id }
        }
        .fullScreenCover(item: eligibleRetry, onDismiss: finishRetry) { failure in
            EpisodeAdvanceRetryScene(failure: failure, current: { playback.episodeRetryCurrent(failure) }, retry: {
                guard playback.episodeRetryCurrent(failure), !failure.denied else { return }
                retryQueued = failure; playback.dismissEpisodeRetry(failure, queuedRetry: true)
            }, close: { playback.dismissEpisodeRetry(failure) })
            .onAppear { retryPresented = failure }
        }
    }
    private func finishRetry() {
        let queued = retryQueued, old = retryPresented; retryQueued = nil; retryPresented = nil
        if let old { playback.dismissEpisodeRetry(old, queuedRetry: queued?.id == old.id) }
        guard let queued, session.phase == .ready, !session.protectedBrowsingBlocked, !session.resumeGate.blocked,
              !session.hasProtectedPlaybackPresentation, APIClient.shared.isCurrent(queued.context) else { return }
        playback.retryNextEpisode(queued)
    }
    private func finishNavigation() {
        let action = queued, old = presented; queued = nil; presented = nil
        if let old { playback.dismissPostPlay(old) }
        guard let action, session.phase == .ready, !session.protectedBrowsingBlocked, !session.resumeGate.blocked else { return }
        playback.playPostPlay(action.request, context: action.context, operation: action.operation)
    }
}
