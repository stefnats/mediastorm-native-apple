import AetherEngine
import AVKit
import Combine
import UIKit

/// A normal local SDK source, owned by this room/viewer. Only explicit transport
/// actions publish room state; applying a remote observation never echoes it.
final class WatchRoomPlayerViewController: EnginePlayerViewController {
    let session: WatchRoomSession
    private let gate: WatchRoomEngineGate
    private let preparation: WatchRoomPreparation
    private let progress: PlayerProgressWriter
    private var identity: OriginalPlaybackProgress?
    private var loadTask: Task<Void,Never>?
    private var applyTask: Task<Void,Never>?
    private var actionTask: Task<Void,Never>?
    private var cleanupTask: Task<Void,Never>?
    private var pending: WatchRoomObservation?
    private var timer: Timer?
    private var closing = false
    private var loaded = false
    private var hasPlayed = false
    private var sourceFailure: String?
    private var subtitle: Int?
    private let message = UILabel()
    #if os(iOS)
    private lazy var controls = MobilePlayerControls(title:session.room.title,subtitle:String(localized:"Watch Together"))
    override var hasTouchTransport: Bool { true }
    #else
    private lazy var hud = SoftwareTransportHUD(title:session.room.title,subtitle:String(localized:"Watch Together"))
    override var preferredFocusEnvironments: [UIFocusEnvironment] { hud.wantsFocus ? [hud] : super.preferredFocusEnvironments }
    override var softwareHUDHasOpenLayer: Bool { hud.rowFocused || hud.isInfoShowing }
    override func closeSoftwareHUDLayer() { hud.releaseRow(); hud.setInfo(visible:false) }
    #endif

    init(engine: AetherEngine, session: WatchRoomSession) {
        self.session = session; gate = WatchRoomEngineGate(session:session)
        preparation = WatchRoomPreparation(context:session.context)
        progress = PlayerProgressWriter(viewer:session.context)
        super.init(engine:engine,logCategory:"watch-room")
        audioOffsetKey = session.target.playback.audioOffsetKey
    }
    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // AVKit's independent scrubber/AirPlay transport cannot bypass the
        // room callbacks, on either the native or software video route.
        showsPlaybackControls = false
        Self.fill(subtitleOverlay,in:overlayHost); overlayHost.addSubview(subtitleOverlay)
        message.textColor = .white; message.numberOfLines = 3; message.textAlignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(message)
        NSLayoutConstraint.activate([message.centerXAnchor.constraint(equalTo:view.centerXAnchor),
            message.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:24),
            message.widthAnchor.constraint(lessThanOrEqualTo:view.widthAnchor,multiplier:0.75)])
        #if os(iOS)
        Self.fill(controls,in:view); view.addSubview(controls); controls.setOwnsTransport(true)
        controls.transport.setExternalPlaybackAllowed(false)
        controls.onClose = { [weak self] in self?.requestClose() }
        controls.onPlayPause = { [weak self] in self?.toggle() }
        controls.onSkip = { [weak self] delta in self?.skip(delta) }
        controls.onScrub = { [weak self] position, ended in if ended { self?.change(position:position) } }
        #else
        Self.fill(hud,in:view); view.addSubview(hud)
        hud.onFocusChange = { [weak self] in self?.setNeedsFocusUpdate(); self?.updateFocusIfNeeded() }
        hud.flash()
        #endif
        engine.$currentAVPlayer.receive(on:DispatchQueue.main).sink { player in
            player?.allowsExternalPlayback = false
        }.store(in:&cancellables)
        engine.$videoRoute.receive(on:DispatchQueue.main).sink { [weak self] route in
            guard let self, !closing else { return }
            mountSoftwareSurface(route == .software); showsPlaybackControls = false
            Self.fill(subtitleOverlay,in:overlayHost); overlayHost.addSubview(subtitleOverlay)
        }.store(in:&cancellables)
        engine.$subtitleCues.receive(on:DispatchQueue.main).sink { [weak self] in self?.subtitleOverlay.setCues($0) }.store(in:&cancellables)
        engine.clock.$sourceTime.receive(on:DispatchQueue.main).sink { [weak self] in self?.subtitleOverlay.update(sourceTime:$0) }.store(in:&cancellables)
        SubtitleStyleStore.shared.$style.receive(on:DispatchQueue.main).sink { [weak self] in self?.subtitleOverlay.style = $0 }.store(in:&cancellables)
        engine.$audioTracks.receive(on:DispatchQueue.main).sink { [weak self] _ in self?.menus() }.store(in:&cancellables)
        engine.$subtitleTracks.receive(on:DispatchQueue.main).sink { [weak self] _ in self?.menus() }.store(in:&cancellables)
        engine.$state.receive(on:DispatchQueue.main).sink { [weak self] state in
            guard let self, !closing else { return }
            switch state {
            case let .error(detail): sourceFailure = detail; engine.pause()
            case .ended: sample(ended:true); sourceFailure = String(localized:"Playback ended. Leave the room before choosing another source.")
            default: break
            }
            updateChrome()
        }.store(in:&cancellables)
        engine.clock.$currentTime.receive(on:DispatchQueue.main).sink { [weak self] _ in self?.updateChrome() }.store(in:&cancellables)
        session.$observation.receive(on:DispatchQueue.main).sink { [weak self] next in self?.schedule(next) }.store(in:&cancellables)
        session.$uncertain.receive(on:DispatchQueue.main).sink { [weak self] uncertain in
            if uncertain { self?.engine.pause(); self?.updateChrome() }
        }.store(in:&cancellables)
        menus(); updateChrome()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard loadTask == nil, !closing else { return }
        matchContent = view.window?.displayCriteriaMatchingEnabled ?? false
        session.startPolling()
        loadTask = Task { [self] in
            do {
                await TrackSettingsStore.shared.loadIfNeeded(); try gate.check()
                let prepared = try await preparation.prepare(session.target)
                try gate.check()
                var options = baseLoadOptions(); options.httpHeaders = prepared.request.allHTTPHeaderFields ?? [:]
                let tracks = prepared.tracks
                try await gate.start(expectedDuration:prepared.status.duration ?? 0,load:{
                    _ = try await self.engine.load(url:prepared.request.url!,startPosition:self.session.observation.position(),
                        options:options,audioSourceStreamIndex:tracks.audioStreamIndex.map(Int32.init))
                    guard !self.engine.isLive else { throw WatchRoomError.unavailable }
                    let actualTracks = tracks.isClientPick ? tracks : TrackPreferences.overridden(tracks.selection,
                        audio:self.engine.audioTracks.filter { !$0.isExternal }.map(ClientTrackSelector.Stream.init),
                        subtitles:OnlineSubtitles.containerTracks(self.engine.subtitleTracks).map(ClientTrackSelector.Stream.init)) ?? tracks
                    if let audio = actualTracks.audioTrackID(in:self.engine.audioTracks) { self.engine.selectAudioTrack(index:audio) }
                    self.subtitle = actualTracks.subtitlesExplicitlyOff ? nil : actualTracks.subtitleTrackID(in:self.engine.subtitleTracks)
                    if let subtitle = self.subtitle { self.engine.selectSubtitleTrack(index:subtitle) } else { self.engine.clearSubtitle() }
                },duration:{ self.engine.duration },position:{ self.engine.currentTime },
                    seek:{ await self.engine.seek(to:$0) },pause:{ self.engine.pause() })
                try gate.check()
                identity = OriginalPlaybackProgress(request:session.target.playback,path:prepared.path,context:session.context)
                loaded = true; menus(); schedule(session.observation)
                timer = Timer.scheduledTimer(withTimeInterval:10,repeats:true) { [weak self] _ in
                    Task { @MainActor in self?.sample(ended:false) }
                }
            } catch {
                if !closing { sourceFailure = error.localizedDescription; engine.pause(); updateChrome() }
            }
        }
    }

    private func schedule(_ next: WatchRoomObservation) {
        guard !closing else { return }
        if next.room.status == "ended" { requestClose(); return }
        pending = next
        guard loaded, sourceFailure == nil, applyTask == nil, actionTask == nil else { return }
        applyTask = Task { [self] in
            defer { applyTask = nil }
            while let next = pending, !closing {
                pending = nil
                do {
                    _ = try await gate.apply(next,duration:{ self.engine.duration },position:{ self.engine.currentTime },
                        seek:{ await self.engine.seek(to:$0) },pause:{ self.engine.pause() },play:{ self.engine.play() })
                    updateChrome()
                } catch {
                    if !closing, !Task.isCancelled { engine.pause(); message.text = error.localizedDescription }
                    return
                }
            }
        }
    }
    private func toggle() { change(paused:session.room.status == "playing" && !session.room.waitingForReady) }
    private func skip(_ delta: Double) { change(position:min(max(0,engine.currentTime+delta),engine.duration)) }
    private func change(position: Double? = nil, paused: Bool? = nil) {
        guard loaded, sourceFailure == nil, !closing, actionTask == nil, !session.busy, !session.uncertain, session.current() else { return }
        let applying = applyTask; applying?.cancel()
        actionTask = Task { [self] in
            await applying?.value
            defer { actionTask = nil; schedule(session.observation) }
            do {
                try gate.check()
                let wasPaused = session.room.status != "playing" || session.room.waitingForReady
                engine.pause()
                if let position {
                    guard position.isFinite, position >= 0, position <= engine.duration else { throw WatchRoomError.unavailable }
                    await engine.seek(to:position); try gate.check()
                    guard abs(engine.currentTime-position) <= 1 else { throw WatchRoomError.unavailable }
                }
                // Actual SDK time, not a requested seek target or the room clock.
                _ = await session.sendState(paused:paused ?? wasPaused,position:engine.currentTime,duration:engine.duration)
            } catch { if !closing { message.text = error.localizedDescription } }
        }
    }
    private func updateChrome() {
        guard !closing else { return }
        session.buffering = engine.isBuffering || !loaded || sourceFailure != nil
        if !session.current() { engine.pause() }
        if loaded, engine.state == .playing, session.current(), !session.room.waitingForReady { hasPlayed = true }
        message.text = sourceFailure ?? session.message ?? (!loaded ? String(localized:"Preparing your own room source…") :
            (session.room.waitingForReady ? String(localized:"Waiting for everyone to be ready") : nil))
        #if os(iOS)
        controls.update(position:engine.currentTime,duration:engine.duration,paused:engine.state != .playing)
        #else
        hud.update(position:engine.currentTime,duration:engine.duration,paused:engine.state != .playing)
        #endif
    }
    private func menus() {
        guard !closing else { return }
        let audio = engine.audioTracks.filter { !$0.isExternal }.map { track in
            UIAction(title:track.audioMenuTitle,state:engine.activeAudioTrackIndex == track.id ? .on : .off) { [weak self] _ in
                guard let self, loaded, session.current(), !closing else { return }
                engine.selectAudioTrack(index:track.id); menus()
            }
        }
        var subtitles: [UIMenuElement] = [UIAction(title:String(localized:"Off"),state:subtitle == nil ? .on : .off) { [weak self] _ in
            self?.subtitle = nil; self?.engine.clearSubtitle(); self?.menus()
        }]
        subtitles += engine.subtitleTracks.filter { !$0.isExternal }.map { track in
            UIAction(title:track.subtitleMenuTitle,state:subtitle == track.id ? .on : .off) { [weak self] _ in
                guard let self, !closing else { return }; subtitle = track.id; engine.selectSubtitleTrack(index:track.id); menus()
            }
        }
        let refresh = UIAction(title:String(localized:"Read current room"),image:UIImage(systemName:"arrow.clockwise")) { [weak self] _ in
            guard let self, actionTask == nil, !closing else { return }
            actionTask = Task { [self] in await session.refresh(); actionTask = nil; schedule(session.observation) }
        }
        let leave = UIAction(title:String(localized:"Leave room"),image:UIImage(systemName:"xmark")) { [weak self] _ in self?.requestClose() }
        let entries = [UIMenu(title:String(localized:"Audio"),image:UIImage(systemName:"speaker.wave.2"),children:audio),
            UIMenu(title:String(localized:"Subtitles"),image:UIImage(systemName:"captions.bubble"),children:subtitles),
            UIMenu(title:String(localized:"Room"),image:UIImage(systemName:"person.2"),children:[refresh,leave])]
        #if os(iOS)
        controls.setMenus(entries)
        #else
        hud.setMenus(entries)
        #endif
    }
    private func sample(ended: Bool) {
        guard loaded, hasPlayed, let identity, engine.currentTime.isFinite, engine.currentTime > 0,
              engine.duration.isFinite, engine.duration > 0 else { return }
        progress.submit(identity.body(position:engine.currentTime,duration:engine.duration,paused:engine.state != .playing,ended:ended),ended:ended)
    }
    private func beginCleanup() -> Task<Void,Never> {
        if let cleanupTask { return cleanupTask }
        let ended = engine.state == .ended
        closing = true; gate.close(); timer?.invalidate(); timer = nil
        loadTask?.cancel(); applyTask?.cancel(); actionTask?.cancel(); audioOffsetTask?.cancel(); engine.pause()
        let work = Task { [self] in
            await preparation.closeAndDrain()
            await loadTask?.value; await applyTask?.value; await actionTask?.value
            sample(ended:ended)
            try? await progress.stopAndDrain(requireKnownAcknowledgements:false)
            engine.stop(); cancellables.removeAll()
            _ = await session.close()
            WatchRoomPlayback.finished(self)
        }
        cleanupTask = work
        return work
    }
    private func requestClose() {
        let cleanup = beginCleanup()
        Task { [self] in await cleanup.value; if presentingViewController != nil { dismiss(animated:true) } }
    }
    override func finish() { _ = beginCleanup() }

    #if os(tvOS)
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else { return super.pressesBegan(presses,with:event) }
        switch press.type {
        case .menu: if softwareHUDHasOpenLayer { closeSoftwareHUDLayer() } else { requestClose() }
        case .playPause: toggle(); hud.flash()
        case .select: if !hud.rowFocused { toggle(); hud.flash() } else { super.pressesBegan(presses,with:event) }
        case .leftArrow,.rightArrow:
            if hud.rowFocused { super.pressesBegan(presses,with:event) } else { skip(press.type == .leftArrow ? -10 : 10); hud.flash() }
        case .upArrow: hud.focusRow()
        case .downArrow: hud.releaseRow(); hud.setInfo(visible:!hud.isInfoShowing)
        default: super.pressesBegan(presses,with:event)
        }
    }
    #endif
}
