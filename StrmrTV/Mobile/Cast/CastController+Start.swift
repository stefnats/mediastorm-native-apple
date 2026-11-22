#if os(iOS)
import Foundation

/// Starting a cast, for a title (`start`) and a live channel (`startLive`) alike: what was
/// casting is replaced, the remote comes up at once, and the media is built and loaded on the
/// receiver, with a failure shown on the remote.
extension CastController {
    /// What a start has built for the receiver: its connection, the media to load, the server
    /// HLS session behind it (kept alive, stopped with the cast) and, for a title, what watch
    /// progress is reported against (nil for a live channel).
    struct Prepared {
        let transport: CastTransport
        let media: CastMedia
        let hlsSessionID: String?
        let playback: OriginalPlaybackProgress?
        var liveContext: SourceActionContext? = nil
    }

    func begin(_ session: Session, prepare: @escaping @MainActor () async throws -> Prepared) async {
        let generation = UUID()
        castStartGeneration = generation
        let previous = startTask
        startTask = nil
        previous?.cancel()
        await previous?.value
        let device = session.device
        await finish(reason: "replaced by a new cast", stopReceiver: transport?.device.id != device.id, cancelStarting: false)
        guard generation == castStartGeneration, liveStartContext == nil || hlsSessionID == nil else { return }
        self.session = session
        CastPresenter.showRemote()
        let task = Task {
            // A server session built for this start that the cast hasn't taken over yet.
            var orphan: String?
            var orphanContext: SourceActionContext?
            do {
                guard generation == castStartGeneration, !Task.isCancelled else { throw CancellationError() }
                let prepared = try await prepare()
                orphan = prepared.hlsSessionID
                orphanContext = prepared.liveContext
                try Task.checkCancellation()
                guard generation == castStartGeneration else { throw CancellationError() }
                hlsSessionID = prepared.hlsSessionID
                liveStartContext = prepared.liveContext
                playback = prepared.playback
                transport = prepared.transport
                orphan = nil
                try await prepared.transport.load(prepared.media)
                try Task.checkCancellation()
                guard generation == castStartGeneration else { throw CancellationError() }
                self.session?.phase = .active
                self.session?.canSeek = prepared.transport.canSeek && !prepared.media.isLive
                self.session?.state.duration = prepared.media.isLive ? 0 : prepared.media.duration ?? 0
                self.session?.state.position = prepared.media.startPosition
                startPolling()
            } catch is CancellationError {
                if let orphan { await stopCastHLS(orphan, context: orphanContext) }
                if generation == castStartGeneration, !Task.isCancelled, hlsSessionID == nil {
                    self.session = nil
                    CastPresenter.dismissRemote()
                }
            } catch {
                log.error("cast to \(device.name) failed: \(error.localizedDescription)")
                if let orphan { await stopCastHLS(orphan, context: orphanContext) }
                await transport?.stop()
                transport = nil
                if let id = hlsSessionID { await stopCastHLS(id, context: liveStartContext) }
                if liveStartContext == nil { hlsSessionID = nil }
                playback = nil
                self.session?.phase = .failed(error.localizedDescription)
            }
        }
        startTask = task
        await task.value
    }
    /// Cleanup is independently owned even when the requesting start was cancelled.
    func stopCastHLS(_ id: String, context: SourceActionContext?) async {
        let cleanup = Task { () -> Bool in
            if let context {
                do { try await APIClient.shared.stopLiveSessionStrict(id, context: context); return true }
                catch { return false }
            }
            await APIClient.shared.stopLiveSession(id)
            return true
        }
        if await cleanup.value {
            if hlsSessionID == id { hlsSessionID = nil; liveStartContext = nil }
        } else {
            // Retain the known creator and ID. Another explicit Cast/Stop may
            // settle it first; a failed stop cannot admit another provider open.
            hlsSessionID = id; liveStartContext = context
            session?.phase = .failed(String(localized: "The previous live session stop was not confirmed. Stop Casting before trying again."))
        }
    }

}
#endif
