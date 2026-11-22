import SwiftUI
import UIKit

extension PlayerViewController {
    func releaseReportAction() -> UIAction {
        let available = currentSource.prequeueID != nil && currentSource.prequeueContext != nil && !engine.isLive && !playsDownload
        return UIAction(title: String(localized: "Report / Change Source…"),
                        image: UIImage(systemName: "exclamationmark.bubble"),
                        attributes: available ? [] : [.disabled]) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.presentReleaseReport() }
        }
    }

    private func presentReleaseReport() {
        guard !didFinish, presentedViewController == nil, let id = currentSource.prequeueID,
              let context = currentSource.prequeueContext else { return }
        guard APIClient.shared.isCurrent(context) else {
            subtitleStatus.show(String(localized: "Profile or connection changed. Reopen playback before reporting."), hideAfter: 5)
            return
        }
        let model = ReleaseReportModel(prequeueID: id, context: context)
        releaseReportModel?.close()
        releaseReportModel = model
        let host = UIHostingController(rootView: ReleaseReportView(model: model,
            position: max(0, lastKnownPosition), onPlay: { [weak self] id, position in
                guard let self, !self.didFinish else {
                    model.close()
                    Task { try? await APIClient.shared.cancelReleaseReplacement(id, context: model.context) }
                    return
                }
                self.playReportedAlternative(id: id, position: position, context: model.context)
            }, onClose: { [weak self] in self?.presentedViewController?.dismiss(animated: true) }))
        host.modalPresentationStyle = .overFullScreen
        present(host, animated: true)
    }

    private func playReportedAlternative(id: String, position: Double, context: SourceActionContext) {
        guard !didFinish, !isAdvancing else {
            Task { try? await APIClient.shared.cancelReleaseReplacement(id, context: context) }
            return
        }
        isAdvancing = true
        let carry = currentTrackCarry()
        var next = PlaybackRequest(title: request.title, episode: request.episode,
            start: position > 0 ? .seconds(position) : nil, following: request.following, artwork: request.artwork)
        next.speed = playbackSpeed
        // Dismiss the dialog and then the original player. Only this explicit
        // press transfers the acknowledged replacement to the coordinator.
        presentedViewController?.dismiss(animated: false)
        dismiss(animated: true) {
            PlaybackCoordinator.shared.playReportedAlternative(next, id: id, context: context, carry: carry)
        }
    }
}
