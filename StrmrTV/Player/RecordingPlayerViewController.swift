import AetherEngine
import AVKit
import UIKit

/// Opens a Live TV recording over whatever is on screen.
@MainActor
enum RecordingPlayback {
    static func play(_ recording: Recording) {
        let context = APIClient.shared.sourceContext()
        if recording.capturePresent, recording.singleActivePart == nil {
            return choosePart(recording, context: context)
        }
        do {
            let source: RecordingPlaybackSource
            if recording.capturePresent { source = try .singleActive(recording, context: context) }
            else { source = try .legacy(recording, context: context) }
            present(source)
        } catch { show(error) }
    }

    static func playPart(_ recording: Recording, index: Int, context: SourceActionContext, dismissPresented: Bool = false) {
        do {
            try APIClient.shared.requireSourceContext(context)
            let source = try RecordingPlaybackSource.part(recording, index: index, context: context)
            if dismissPresented, let top = presenter(), top.presentingViewController != nil {
                top.dismiss(animated: true) { present(source) }
            } else { present(source) }
        } catch { show(error) }
    }

    private static func presenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private static func present(_ source: RecordingPlaybackSource) {
        let coordinator = PlaybackCoordinator.shared
        guard coordinator.resolving == nil, let engine = coordinator.sharedEngine else { return }
        let top = presenter()
        guard let top, !(top is EnginePlayerViewController) else { return }
        guard APIClient.shared.isCurrent(source.context) else { return }
        top.present(RecordingPlayerViewController(engine: engine, recording: source.recording, source: source), animated: true)
    }

    private static func choosePart(_ recording: Recording, context: SourceActionContext) {
        guard let top = presenter(), !(top is EnginePlayerViewController) else { return }
        let alert = UIAlertController(title: String(localized: "Choose a captured part"), message: recording.captureNotice, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        for part in recording.playableParts {
            alert.addAction(UIAlertAction(title: part.label, style: .default) { [weak alert] _ in
                alert?.dismiss(animated: true) { playPart(recording, index: part.index, context: context) }
            })
        }
        top.present(alert, animated: true)
    }

    private static func show(_ error: Error) {
        guard let top = presenter(), !(top is UIAlertController) else { return }
        let alert = UIAlertController(title: String(localized: "Recording unavailable"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Close"), style: .cancel))
        top.present(alert, animated: true)
    }
}

/// A Live TV recording in the stock tvOS player over AetherEngine, from the start, with no
/// resume or watch state (the Expo player opens recordings with progress tracking off).
///
/// A finished recording plays its file (`/api/live/recordings/{id}/stream`) as any VOD file.
/// One still recording plays an HLS session over the growing file: an EVENT playlist listing
/// every segment from 0, which AVPlayer reloads by itself, so the timeline grows under a
/// normal scrubber; about 20 s after the last write the server ends the playlist and it plays
/// to the true end. AVKit draws an open-ended playlist as a live stream (a LIVE pill and wall
/// clock times), so a growing recording gets the app's own transport readout instead: position
/// over the recorded length, which grows as it plays. The session is kept alive every 20 s (which also says whether the server
/// still follows the file) and stopped on close. If playback reaches an end while the server
/// still follows the file (a source stall over 20 s ended the playlist early), a new session
/// resumes where playback was.
final class RecordingPlayerViewController: EnginePlayerViewController {
    let recording: Recording
    let growing: Bool
    private let source: RecordingPlaybackSource?
    private let sourceGuard: RecordingSourceGuard?
    private var loadTask: Task<Void, Never>?
    private(set) var didFinish = false
    private(set) var lastPosition: Double = 0
    #if os(iOS)
    /// The phone's touch controls (`RecordingPlayer+Mobile`): the transport while the player owns
    /// it, and the menu row over AVKit's chrome otherwise.
    lazy var mobileControls = MobilePlayerControls(title: recording.displayTitle, subtitle: recording.channelName)
    lazy var mobileChromeTracker = MobileChromeVisibility(root: view, controls: mobileControls)
    override var hasTouchTransport: Bool { true }
    #else
    private lazy var softwareHUD = SoftwareTransportHUD(title: recording.displayTitle, subtitle: recording.channelName)
    private lazy var recBadge = RecordingBadge()
    #endif

    // The growing recording's HLS session.
    private var sessionID: String?
    private var keepAliveTimer: Timer?
    /// The server's last word on whether it still follows the file.
    private var serverGrowing = true
    /// A session is loading (and seeking to its start): its clock is not the viewer's position.
    private var opening = false
    /// Fresh sessions opened after an early end; bounded so a dead source can't loop.
    private var resumes = 0
    private static let resumeBudget = 3
    private static let seekStep: Double = 10
    var scrubTarget: Double?
    private var scrubCommit: DispatchWorkItem?

    /// Shown while the server still follows the recording.
    static let recBadgeText = String(localized: "● REC")

    init(engine: AetherEngine, recording: Recording, source: RecordingPlaybackSource? = nil) {
        self.recording = recording
        self.source = source
        sourceGuard = source.flatMap { value in value.recording.capturePresent ? RecordingSourceGuard(value) : nil }
        if let source {
            switch source.kind {
            case .legacyGrowing, .singleActive: growing = true
            case .legacyWhole, .part: growing = false
            }
        } else { growing = recording.status == .running || recording.status == .starting }
        super.init(engine: engine, logCategory: "recording-player")
        audioOffsetKey = AudioOffsetStore.Key.recording(recording.id)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindEngine()
        setInfoPanel(title: recording.displayTitle, subtitle: recording.channelName, description: recording.description)
        installStreamInfo(file: nil, source: StreamSource.joined([String(localized: "Recording"), recording.channelName]))
        #if os(iOS)
        installMobileRecordingControls()
        #else
        installAudioOffsetMenu()
        if growing {
            Self.fill(recBadge, in: overlayHost)
            overlayHost.addSubview(recBadge)
            showsPlaybackControls = false
            Self.fill(softwareHUD, in: view)
            view.addSubview(softwareHUD)
            softwareHUD.flash()
        }
        #endif
    }

    #if !os(iOS)
    /// The transport bar's (and the growing recording's HUD's) one menu: Audio Offset.
    private func installAudioOffsetMenu() {
        let menu = audioOffsetMenu { [weak self] in self?.installAudioOffsetMenu() }
        transportBarCustomMenuItems = [menu]
        softwareHUD.setMenus([menu])
    }
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard loadTask == nil, !didFinish else { return }
        matchContent = view.window?.displayCriteriaMatchingEnabled ?? false
        log.notice("playing recording \(recording.id) (\(recording.status.rawValue)\(growing ? ", growing hls" : ""))")
        open(at: 0)
    }

    /// The file for a finished recording; for a growing one a new HLS session (any old one stopped).
    private func open(at position: Double) {
        loadTask?.cancel()
        opening = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if recording.capturePresent, sourceGuard == nil {
                    throw APIError.notReady("Choose an actual captured part before playback")
                }
                if let sourceGuard { try await sourceGuard.validateForOpen() }
                var options = baseLoadOptions()
                let url: URL
                if growing {
                    endSession()
                    let session: (url: URL, sessionID: String)
                    if let source, case .singleActive = source.kind {
                        session = try await APIClient.shared.startRecordingHLS(source)
                    } else { session = try await APIClient.shared.startRecordingHLS(recording) }
                    do {
                        try Task.checkCancellation()
                        guard !didFinish else { throw CancellationError() }
                        if let sourceGuard { try await sourceGuard.validateForOpen() }
                    } catch {
                        if let source, source.recording.capturePresent { await APIClient.shared.stopRecordingHLS(session.sessionID, context: source.context) }
                        else { await APIClient.shared.stopLiveSession(session.sessionID) }
                        throw error
                    }
                    sessionID = session.sessionID
                    serverGrowing = true
                    startKeepAlive()
                    url = session.url
                    // The server's playlist straight to AVPlayer, as a seekable programme (not live):
                    // AVPlayer reloads an EVENT playlist itself and keeps every segment seekable.
                    options.nativeRemoteHLS = true
                } else if let source, case .part = source.kind {
                    let request = try source.partRequest()
                    guard let value = request.url else { throw APIError.notReady("The part address is unavailable") }
                    url = value
                } else {
                    url = APIClient.shared.recordingStreamURL(recording)
                }
                if let source, source.recording.capturePresent {
                    try sourceGuard?.requireCurrent()
                    let request = try source.context.request("GET", path: "/api/live/recordings/\(APIClient.segment(recording.id))/stream")
                    options.httpHeaders = request.allHTTPHeaderFields ?? [:]
                }
                _ = try await engine.load(url: url, startPosition: position, options: options)
                if let sourceGuard { try sourceGuard.requireCurrent() }
                try Task.checkCancellation()
                guard !didFinish else { throw CancellationError() }
                // An EVENT playlist starts at its live edge unless told otherwise.
                if growing, position > 0 { try await waitForPlaylist(toReach: position) }
                if growing, abs(engine.clock.currentTime - position) > 5 { await seekPlayback(to: position) }
                if let sourceGuard { try sourceGuard.requireCurrent() }
                try Task.checkCancellation()
                guard !didFinish else { throw CancellationError() }
                opening = false
                log.info("opened at \(Int(position))s, duration \(Int(engine.duration))s")
                engine.play()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: Session

    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAlive() }
        }
    }

    private func keepAlive() {
        guard let id = sessionID else { return }
        let paused = engine.state == .paused, buffering = engine.isBuffering, time = lastPosition
        Task { [weak self] in
            guard let self else { return }
            let value: Bool?
            if let source, source.recording.capturePresent {
                guard APIClient.shared.isCurrent(source.context) else { fail(String(localized: "The original recording profile changed. Reopen its parts.")); return }
                value = await APIClient.shared.keepRecordingHLSAlive(id, time: time, paused: paused, buffering: buffering, context: source.context)
            } else { value = await APIClient.shared.keepRecordingHLSAlive(id, time: time, paused: paused, buffering: buffering) }
            guard let growing = value, !didFinish, sessionID == id else { return }
            if growing != serverGrowing { log.info("server growing: \(growing)") }
            serverGrowing = growing
            #if os(iOS)
            mobileControls.transport.setBadge(growing ? Self.recBadgeText : nil)
            #else
            recBadge.isHidden = !growing
            #endif
        }
    }

    private func endSession() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        guard let id = sessionID else { return }
        sessionID = nil
        if let source, source.recording.capturePresent {
            Task { await APIClient.shared.stopRecordingHLS(id, context: source.context) }
        } else { Task { await APIClient.shared.stopLiveSession(id) } }
    }

    // MARK: Engine binding

    private func bindEngine() {
        engine.$videoRoute
            .receive(on: DispatchQueue.main)
            .sink { [weak self] route in self?.setSoftwareSurface(mounted: route == .software) }
            .store(in: &cancellables)
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                if time > 0, !opening { lastPosition = time }
                guard ownsTransport else { return }
                updateTransport(position: scrubTarget ?? time)
            }
            .store(in: &cancellables)
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .ended: self?.reachedEnd()
                case let .error(message): self?.fail(message)
                default: break
                }
            }
            .store(in: &cancellables)
    }

    /// The end of the programme, unless the server still follows the file (the playlist ended
    /// early on a long source stall): then a new session picks up where playback was.
    /// The server is asked afresh: its last keepalive may predate the playlist's end by 20 s.
    private func reachedEnd() {
        guard !didFinish, !opening else { return }
        guard growing, resumes < Self.resumeBudget, let id = sessionID else { return endPlayback() }
        let position = lastPosition
        Task { [weak self] in
            guard let self else { return }
            let following: Bool?
            if let source, source.recording.capturePresent {
                following = await APIClient.shared.keepRecordingHLSAlive(id, time: position, paused: false, buffering: false, context: source.context)
            } else { following = await APIClient.shared.keepRecordingHLSAlive(id, time: position, paused: false, buffering: false) }
            guard !didFinish, sessionID == id else { return }
            guard following == true else { return endPlayback() }
            resumes += 1
            log.notice("playlist ended while the server still follows the file: new session at \(Int(position))s")
            open(at: position)
        }
    }

    private func endPlayback() {
        log.notice("recording ended at \(Int(lastPosition))s")
        dismiss(animated: true)
    }

    /// The app's readout and remote handling replace AVKit's: on the software route (no AVPlayer)
    /// and for a growing recording (AVKit would show it as live).
    var ownsTransport: Bool { growing || softwareSurfaceMounted }

    /// The length to scrub over: for a growing recording, as far as the playlist reaches so far.
    var transportDuration: Double {
        let seekableEnd = player?.currentItem?.seekableTimeRanges.last.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds } ?? 0
        return max(engine.duration, seekableEnd.isFinite ? seekableEnd : 0)
    }

    private func setSoftwareSurface(mounted: Bool) {
        guard mountSoftwareSurface(mounted) else { return }
        if growing { showsPlaybackControls = false }
        #if os(iOS)
        mobileSoftwareSurfaceChanged()
        #else
        if mounted, softwareHUD.superview == nil {
            Self.fill(softwareHUD, in: view)
            view.addSubview(softwareHUD)
            softwareHUD.flash()
        } else if !mounted, !growing {
            softwareHUD.removeFromSuperview()
        }
        #endif
    }

    /// The readout at `position`: the phone's controls or the TV's HUD.
    private func updateTransport(position: Double) {
        #if os(iOS)
        mobileControls.update(position: position, duration: transportDuration, paused: engine.state == .paused)
        #else
        softwareHUD.update(position: position, duration: transportDuration, paused: engine.state == .paused)
        #endif
    }

    #if os(tvOS)
    override var softwareHUDHasOpenLayer: Bool { ownsTransport && softwareHUD.isInfoShowing }

    override func closeSoftwareHUDLayer() {
        softwareHUD.setInfo(visible: false)
    }

    override func streamInfoDidChange(_ info: StreamInfo) {
        softwareHUD.setDetails(info.summary)
    }

    /// Without AVKit's chrome: Select / Play-Pause toggle, Left / Right seek 10 s, Down opens the
    /// Info card, Menu closes it or the player.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard ownsTransport, let press = presses.first else { return super.pressesBegan(presses, with: event) }
        switch press.type {
        case .select, .playPause: engine.togglePlayPause()
        case .leftArrow: seek(by: -Self.seekStep)
        case .rightArrow: seek(by: Self.seekStep)
        case .downArrow: softwareHUD.setInfo(visible: !softwareHUD.isInfoShowing)
        case .upArrow: softwareHUD.setInfo(visible: false)
        case .menu:
            // An open Info card is closed by the base class's Menu recognizer.
            if !softwareHUD.isInfoShowing { dismiss(animated: true) }
            return
        default: return super.pressesBegan(presses, with: event)
        }
        softwareHUD.flash()
    }
    #else
    override func streamInfoDidChange(_ info: StreamInfo) {
        mobileControls.setDetails(info.summary)
    }
    #endif

    /// A run of presses is one seek: the target moves with each press (and the readout with it),
    /// and the seek goes out once the presses pause.
    func seek(by delta: Double) {
        let target = min(max(0, (scrubTarget ?? lastPosition) + delta), max(0, transportDuration - 1))
        scrubTarget = target
        updateTransport(position: target)
        scrubCommit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let target = scrubTarget else { return }
            log.info("seek to \(Int(target))s of \(Int(transportDuration))s")
            Task {
                await self.seekPlayback(to: target)
                self.scrubTarget = nil
            }
        }
        scrubCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// A new session's playlist starts short and catches up quickly (the server copies, not
    /// encodes): wait, up to 30 s, for it to reach where playback resumes.
    private func waitForPlaylist(toReach position: Double) async throws {
        for _ in 0..<60 where transportDuration < position + 2 {
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// The engine clamps a seek to its duration, which an open-ended playlist doesn't have (0), so
    /// a growing recording's seeks go to AVPlayer, which seeks within the playlist so far.
    func seekPlayback(to seconds: Double) async {
        guard growing, let avPlayer = player ?? engine.currentAVPlayer else { return await engine.seek(to: seconds) }
        await avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero,
                            toleranceAfter: .zero)
    }

    // MARK: Lifecycle

    private func fail(_ message: String) {
        guard !didFinish else { return }
        log.error("recording playback failed: \(message)")
        PlaybackCoordinator.shared.errorMessage = message
        dismiss(animated: true)
    }

    override func finish() {
        guard !didFinish else { return }
        didFinish = true
        sourceGuard?.close()
        log.notice("player closed at \(Int(lastPosition))s")
        loadTask?.cancel()
        scrubCommit?.cancel()
        #if os(iOS)
        mobileChromeTracker.stop()
        #endif
        endSession()
        cancellables.removeAll()
        settingsHider.stop()
        player = nil
        setSoftwareSurface(mounted: false)
        engine.stop()
        PlaybackCoordinator.shared.playerDidClose()
    }
}

#if os(tvOS)
/// "● REC" at the top right while the server still follows the recording.
private final class RecordingBadge: UIView {
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        label.text = RecordingPlayerViewController.recBadgeText
        label.font = .systemFont(ofSize: 26, weight: .bold)
        label.textColor = .white
        label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        label.textAlignment = .center
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            label.widthAnchor.constraint(equalToConstant: 120),
            label.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif
