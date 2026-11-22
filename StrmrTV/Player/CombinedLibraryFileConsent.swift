import UIKit

/// One explicit from-beginning choice. Cancellation dismisses this exact alert
/// and resumes its continuation once; it never presses Play on the viewer's behalf.
@MainActor
final class CombinedLibraryFileConsent {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var alert: UIAlertController?
    private var completed = false

    func confirm(_ playback: LibraryPlaybackInfo, on presenter: UIViewController) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !completed, !Task.isCancelled else { continuation.resume(returning: false); return }
                self.continuation = continuation
                let notice = playback.playbackNotice ?? String(localized:
                    "This file contains multiple episodes without verified start offsets. It will play from the beginning. Progress applies to the file and does not mark the individual episodes watched.")
                let alert = UIAlertController(title: String(localized: "Play combined episode file?"),
                    message: notice, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "Play From Beginning"), style: .default) { [weak self] _ in self?.finish(true) })
                alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in self?.finish(false) })
                self.alert = alert
                presenter.present(alert, animated: true)
            }
        } onCancel: {
            Task { @MainActor in self.finish(false) }
        }
    }

    private func finish(_ accepted: Bool) {
        guard !completed else { return }
        completed = true
        alert?.dismiss(animated: false)
        alert = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: accepted)
    }
}
