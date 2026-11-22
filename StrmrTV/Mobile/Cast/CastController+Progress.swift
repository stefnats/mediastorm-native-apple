#if os(iOS)
import Foundation

/// The running cast: the receiver polled every second, watch progress every ten (the local
/// player's cadence), the server's HLS session kept warm while a paused receiver asks for
/// nothing, and the end of the media told apart from a stop.
extension CastController {
    /// Polls in a row without an answer before the receiver is presumed gone (TV off, input
    /// switched, network moved: none of these announce themselves).
    private static let failureLimit = 8

    func startPolling(wait: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var failures = 0
            var ticks = 0
            var sawPlayback = false
            while !Task.isCancelled {
                try? await wait()
                guard let self, let transport = self.transport, !Task.isCancelled else { return }
                ticks += 1
                let observed = await transport.status()
                guard !Task.isCancelled, self.transport === transport else { return }
                guard let state = observed else {
                    failures += 1
                    if failures >= Self.failureLimit {
                        await self.finish(reason: "receiver stopped answering", stopReceiver: false)
                        return
                    }
                    continue
                }
                failures = 0
                guard self.transport === transport else { return }
                self.apply(state)
                if state.phase == .playing || state.phase == .paused { sawPlayback = true }
                if state.phase == .finished || (sawPlayback && state.phase == .idle) {
                    // A DLNA renderer says only STOPPED: near the end it finished, else the TV stopped it.
                    let ended = state.phase == .finished || self.isNearEnd
                    await self.finish(reason: ended ? "media finished" : "receiver went idle", stopReceiver: false,
                                      ended: ended)
                    return
                }
                if ticks % 10 == 0 { self.reportProgress(ended: false) }
                // A live session every ten seconds, the live player's cadence.
                if ticks % (self.session?.isLive == true ? 10 : 20) == 0 { self.keepAlive() }
            }
        }
    }

    private func apply(_ state: CastPlaybackState) {
        guard var current = session?.state else { return }
        current.phase = state.phase
        current.position = state.position
        // A receiver that doesn't know the length (a transcode) keeps the one the server gave.
        // A live channel has no length (a receiver may report the seekable window as one).
        if state.duration > 0, session?.isLive == false { current.duration = state.duration }
        if let volume = state.volume { current.volume = volume }
        session?.state = current
    }

    private var isNearEnd: Bool {
        guard let state = session?.state, session?.isLive == false, state.duration > 0 else { return false }
        return state.position >= state.duration - 60 || state.position / state.duration >= 0.92
    }

    /// The `/history/progress` heartbeat the local player sends, for what plays on the TV.
    func reportProgress(ended: Bool) {
        guard let playback, let state = session?.state else { return }
        let duration = state.duration
        let position = ended ? max(state.position, duration) : state.position
        guard duration > 0, position > 0 else { return }
        let body = playback.body(position: position, duration: duration,
                                                   paused: state.phase == .paused, ended: ended)
        Task { await APIClient.shared.reportOriginalProgress(body, context: playback.context) }
    }

    /// The server reaps an HLS session that goes quiet for a minute, and a paused receiver
    /// fetches nothing.
    func keepAlive(heartbeat: ((String, SourceActionContext, Bool) async throws -> Void)? = nil) {
        guard let id = hlsSessionID else { return }
        if let context = liveStartContext {
            guard liveKeepalive == nil else { return }
            let generation = castStartGeneration, owner = UUID(), originalTransport = transport
            let paused = session?.state.phase == .paused
            liveKeepaliveID = owner
            liveKeepalive = Task { [weak self] in
                guard let self else { return }
                defer {
                    if liveKeepaliveID == owner { liveKeepalive = nil; liveKeepaliveID = nil }
                }
                do {
                    if let heartbeat { try await heartbeat(id, context, paused) }
                    else { try await APIClient.shared.keepLiveSessionAliveStrict(id, context: context, paused: paused) }
                } catch {
                    guard generation == castStartGeneration, hlsSessionID == id, liveStartContext == context,
                          transport === originalTransport else { return }
                    // This tracked request owns its denial cleanup. A replacement
                    // joins it; it cannot launch a later detached stop against B.
                    await finish(reason: "live session denied", stopReceiver: true,
                                 expectedGeneration: generation, joinKeepalive: false)
                }
            }
            return
        }
        let paused = session?.state.phase == .paused
        Task {
            _ = try? await APIClient.shared.sendRaw("POST", "/api/video/hls/\(APIClient.segment(id))/keepalive",
                                                    query: ["paused": String(paused)], promptOnLock: false, timeout: 10)
        }
    }

    /// Ends the cast: progress saved, the receiver stopped (when asked), the server session let go.
    func finish(reason: String, stopReceiver: Bool, ended: Bool = false, cancelStarting: Bool = true,
                expectedGeneration: UUID? = nil, joinKeepalive: Bool = true) async {
        if let expectedGeneration, expectedGeneration != castStartGeneration { return }
        if cancelStarting { castStartGeneration = UUID() }
        let generation = castStartGeneration
        let pendingStart = startTask
        startTask = nil
        pendingStart?.cancel()
        await pendingStart?.value
        guard generation == castStartGeneration else { return }
        await receiverStop?.value
        guard generation == castStartGeneration else { return }
        pollTask?.cancel()
        pollTask = nil
        let pendingKeepalive = liveKeepalive
        if joinKeepalive {
            await pendingKeepalive?.value
            guard generation == castStartGeneration else { return }
        }
        // Nothing running: a failed attempt stays on the remote until it is dismissed.
        guard let transport else {
            if let id = hlsSessionID, let context = liveStartContext {
                await stopCastHLS(id, context: context, expectedGeneration: generation)
            }
            guard generation == castStartGeneration else { return }
            if hlsSessionID == nil {
                liveStartContext = nil
                session = nil
                CastPresenter.dismissRemote()
            }
            return
        }
        log.notice("cast to \(transport.device.name) ended: \(reason)")
        reportProgress(ended: ended)
        self.transport = nil
        if stopReceiver {
            let owner = UUID(), stop = Task { await transport.stop() }
            receiverStopID = owner; receiverStop = stop
            await stop.value
            if receiverStopID == owner { receiverStop = nil; receiverStopID = nil }
        }
        guard generation == castStartGeneration else { return }
        if let id = hlsSessionID { await stopCastHLS(id, context: liveStartContext, expectedGeneration: generation) }
        guard generation == castStartGeneration else { return }
        if liveStartContext != nil, hlsSessionID != nil { return }
        hlsSessionID = nil
        liveStartContext = nil
        playback = nil
        session = nil
        CastPresenter.dismissRemote()
        PlaybackCoordinator.shared.playerDidClose()
        NotificationCenter.default.post(name: .continueWatchingChanged, object: nil)
    }
}
#endif
