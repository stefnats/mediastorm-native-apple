import Foundation

/// The cast keeps the viewer and physical/catalogue identity captured at start.
/// A later profile selection on the phone cannot retarget these heartbeats.
struct OriginalPlaybackProgress {
    let request: PlaybackRequest
    let path: String
    let context: SourceActionContext

    func body(position: Double, duration: Double, paused: Bool, ended: Bool) -> [String: Any] {
        request.progressReport(position: position, duration: duration, paused: paused, ended: ended, sourcePath: path)
    }
}
