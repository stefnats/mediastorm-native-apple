import SwiftUI
import UIKit

extension PlayerViewController {
    func releaseReportAction() -> UIAction {
        let available = currentSource.prequeueID != nil && currentSource.viewerContext != nil && !engine.isLive && !playsDownload
        return UIAction(title: String(localized: "Report / Change Source…"),
                        image: UIImage(systemName: "exclamationmark.bubble"),
                        attributes: available ? [] : [.disabled]) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.presentReleaseReport() }
        }
    }

    private func presentReleaseReport() {
        guard !didFinish, presentedViewController == nil, let id = currentSource.prequeueID,
              let context = currentSource.viewerContext else { return }
        guard APIClient.shared.isCurrent(context) else {
            subtitleStatus.show(String(localized: "Profile or connection changed. Reopen playback before reporting."), hideAfter: 5)
            return
        }
        let originalPath = currentSource.streamPath
        let spoken = SpokenAudioModel(id: id, context: context) { [weak self] in
            guard let self, !self.didFinish, !self.engine.isLive, !self.playsDownload,
                  self.currentSource.prequeueID == id, self.currentSource.streamPath == originalPath,
                  self.currentSource.viewerContext == context, self.pendingAudioPick == nil,
                  let track = self.engine.activeAudioTrackIndex,
                  self.engine.audioTracks.contains(where: { $0.id == track && !$0.isExternal }),
                  self.engine.currentTime.isFinite, self.engine.currentTime >= 0 else { return nil }
            return SpokenAudioModel.Selection(track: track, position: self.engine.currentTime)
        }
        let model = ReleaseReportModel(prequeueID: id, context: context, progressOwner: self)
        releaseReportModel?.close()
        releaseReportModel = model
        let host = UIHostingController(rootView: ReleaseReportView(model: model,
            position: max(0, lastKnownPosition), onPlay: { [weak self] transfer, start in
                guard let self, !self.didFinish else {
                    model.close()
                    Task { try? await transfer.lease.release() }
                    return
                }
                self.playReportedAlternative(transfer: transfer, start: start, context: model.context)
            }, onClose: { [weak self] in spoken.close(); self?.presentedViewController?.dismiss(animated: true) }, audioCheck: spoken))
        host.modalPresentationStyle = .overFullScreen
        present(host, animated: true)
    }

    private func playReportedAlternative(transfer: ReleaseReportModel.Transfer, start: ReleaseAlternativeStart,
                                         context: SourceActionContext) {
        guard !didFinish, !isAdvancing, request.allowsExternalSourceSelection else {
            Task { try? await transfer.lease.release() }
            return
        }
        isAdvancing = true
        releaseHandoffTask = Task { [self] in
            var transferred = false
            defer {
                if !transferred {
                    isAdvancing = false
                    Task { try? await transfer.lease.release() }
                }
            }
            do {
                // The old player remains intact until the actual ready response.
                let ready = try await APIClient.shared.releaseReplacementStatus(transfer.id, context: context)
                try ReleaseAlternativeHandoff.validate(ready, id: transfer.id, request: request)
                try Task.checkCancellation()
                guard !didFinish else { throw CancellationError() }
                // Read the engine now, after the last network await; never reuse
                // the position from when the report dialog was opened.
                let position = try start.position(current: engine.currentTime, wrongContent: reportedWrongContent)
                engine.pause()
                progressTimer?.invalidate()
                progressTimer = nil
                stopAutoSwitchWatch()
                try await progressWriter.stopAndDrain(requireKnownAcknowledgements: false)
                try Task.checkCancellation()
                try APIClient.shared.requireSourceContext(context)
                guard !didFinish else { throw CancellationError() }
                let carry = currentTrackCarry()
                var next = PlaybackRequest(title: request.title, episode: request.episode,
                    start: position > 0 ? .seconds(position) : nil, following: request.following, artwork: request.artwork)
                next.speed = playbackSpeed
                transferred = true
                presentedViewController?.dismiss(animated: false)
                dismiss(animated: true) {
                    PlaybackCoordinator.shared.playReportedAlternative(next, ready: ready, lease: transfer.lease,
                                                                        context: context, carry: carry)
                }
            } catch {
                if !didFinish { subtitleStatus.show(error.localizedDescription, hideAfter: 8) }
            }
        }
    }
}
