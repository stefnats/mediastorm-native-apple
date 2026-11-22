import AetherEngine
import AVKit
import Combine
import UIKit

/// The actual player consumes this gate. Receipt expiry covers load, metadata,
/// seek and confirmed start; it never becomes a rolling playback stop timer.
@MainActor
final class RecordingDerivedStartGate {
    let receipt: RecordingProgressReceipt
    private let api: any RecordingDerivedAPI
    private let now: () -> ContinuousClock.Instant
    private(set) var started = false
    private var closed = false
    init(_ receipt: RecordingProgressReceipt, api: any RecordingDerivedAPI = APIClient.shared,
         now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.receipt = receipt; self.api = api; self.now = now
    }
    func close() { closed = true }
    func requireCurrent(adopting: Bool = false) throws {
        try Task.checkCancellation()
        let instant = now()
        guard !closed, api.isCurrent(receipt.original.source.context), receipt.original.ready(now: instant),
              (!adopting || receipt.adoptable(now: instant)) else { throw RecordingDataError.unavailable }
    }
    static func milliseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0, seconds <= 43_200 else { return nil }
        return Int64((seconds * 1000).rounded())
    }
    func compatibleDuration(_ seconds: Double) throws -> Bool {
        if seconds == 0 { return false } // Metadata has not arrived.
        guard seconds.isFinite, seconds > 0, seconds <= 43_200,
              Int64(ceil(seconds * 1000)) == receipt.identity.durationMs else { throw RecordingDataError.unavailable }
        return true
    }
    func start(load: (Double) async throws -> Void, duration: () -> Double, position: () -> Double,
               seek: (Double) async -> Void, play: () -> Void, playing: () -> Bool,
               wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }) async throws {
        try requireCurrent(adopting: true)
        try await api.validateDerivedSource(receipt.original.source)
        try requireCurrent(adopting: true)
        let target = Double(receipt.positionMs) / 1000
        try await load(target)
        try requireCurrent(adopting: true)
        while !(try compatibleDuration(duration())) { try requireCurrent(adopting: true); try await wait() }
        try requireCurrent(adopting: true)
        await seek(target)
        try requireCurrent(adopting: true)
        while Self.milliseconds(position()) != receipt.positionMs { try requireCurrent(adopting: true); try await wait() }
        try await api.validateDerivedSource(receipt.original.source)
        try requireCurrent(adopting: true)
        guard try compatibleDuration(duration()), Self.milliseconds(position()) == receipt.positionMs else { throw RecordingDataError.unavailable }
        play()
        while !playing() { try requireCurrent(adopting: true); try await wait() }
        try requireCurrent(adopting: true)
        started = true
    }
}

@MainActor
enum RecordingDerivedPlayback {
    private static func presenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
    static func play(_ receipt: RecordingProgressReceipt, dismissPresented: Bool) throws {
        let coordinator = PlaybackCoordinator.shared
        guard coordinator.resolving == nil, let engine = coordinator.sharedEngine, let top = presenter(),
              !(top is EnginePlayerViewController), APIClient.shared.isCurrent(receipt.original.source.context) else { throw RecordingDataError.unavailable }
        try receipt.assignPlayer()
        let present = {
            guard APIClient.shared.isCurrent(receipt.original.source.context), receipt.adoptable(),
                  let current = presenter(), !(current is EnginePlayerViewController), coordinator.resolving == nil else {
                PlaybackCoordinator.shared.errorMessage = String(localized: "The original start receipt expired. Read current recording progress again.")
                return
            }
            current.present(RecordingDerivedPlayerViewController(engine: engine, receipt: receipt), animated: true)
        }
        if dismissPresented, top.presentingViewController != nil { top.dismiss(animated: true, completion: present) }
        else { present() }
    }
}

/// The measured Matroska artifact uses the same real native/software engine as
/// other playback, but its own recording CAS writer and original request headers.
final class RecordingDerivedPlayerViewController: EnginePlayerViewController {
    private let receipt: RecordingProgressReceipt
    private let gate: RecordingDerivedStartGate
    private var writer: RecordingProgressWriter!
    private var loadTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var expiryTimer: Timer?
    private var didFinish = false
    private var discarded = false
    private var lastSave: ContinuousClock.Instant = .now
    #if os(iOS)
    private lazy var controls = MobilePlayerControls(title: receipt.original.source.recording.displayTitle, subtitle: String(localized: "Joined recording"))
    private lazy var chrome = MobileChromeVisibility(root: view, controls: controls)
    override var hasTouchTransport: Bool { true }
    #else
    private lazy var hud = SoftwareTransportHUD(title: receipt.original.source.recording.displayTitle, subtitle: String(localized: "Joined recording"))
    #endif

    init(engine: AetherEngine, receipt: RecordingProgressReceipt) {
        self.receipt = receipt; gate = RecordingDerivedStartGate(receipt)
        super.init(engine: engine, logCategory: "recording-derived-player")
        audioOffsetKey = AudioOffsetStore.Key.recording(receipt.identity.recordingId)
        writer = RecordingProgressWriter(receipt) { [weak self] in
            PlaybackCoordinator.shared.errorMessage = String(localized: "Recording progress saving stopped. Return and read progress explicitly.")
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        showsPlaybackControls = false
        let recording = receipt.original.source.recording
        setInfoPanel(title: recording.displayTitle, subtitle: String(localized: "Joined recording"), description: recording.description)
        installStreamInfo(file: nil, source: String(localized: "Measured joined recording"))
        #if os(iOS)
        Self.fill(controls, in: view); view.addSubview(controls)
        controls.onClose = { [weak self] in self?.dismiss(animated: true) }
        controls.onPlayPause = { [weak self] in self?.toggle() }
        controls.onSkip = { [weak self] delta in self?.seek(by: delta) }
        controls.onScrub = { [weak self] time, ended in if ended { self?.seek(to: time) } }
        controls.setMenus([audioOffsetMenu { [weak self] in self?.updateMenus() }])
        chrome.start()
        #else
        updateMenus()
        #endif
        bindEngine()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLifetime() }
        }
    }
    private func updateMenus() {
        let menu = audioOffsetMenu { [weak self] in self?.updateMenus() }
        #if os(iOS)
        controls.setMenus([menu])
        #else
        transportBarCustomMenuItems = [menu]; hud.setMenus([menu])
        #endif
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard loadTask == nil, !didFinish else { return }
        matchContent = view.window?.displayCriteriaMatchingEnabled ?? false
        loadTask = Task { [self] in
            do {
                let request = try APIClient.recordingDerivedMediaRequest(receipt.original)
                guard let url = request.url else { throw RecordingDataError.unavailable }
                var options = baseLoadOptions(); options.httpHeaders = request.allHTTPHeaderFields ?? [:]
                try await gate.start(load: { [self] position in
                    _ = try await engine.load(url: url, startPosition: position, options: options)
                    try gate.requireCurrent(adopting: true)
                    engine.pause()
                }, duration: { self.engine.duration }, position: { self.engine.currentTime },
                   seek: { [self] position in await engine.seek(to: position) },
                   play: { self.engine.play() }, playing: { self.engine.state == .playing })
                showsPlaybackControls = !softwareSurfaceMounted
                lastSave = .now
            } catch is CancellationError {
            } catch { fail() }
        }
    }
    private func checkLifetime() {
        guard !didFinish else { return }
        do { try gate.requireCurrent(adopting: !gate.started) } catch { fail() }
    }
    private func sample() -> Int64? {
        guard gate.started, let value = RecordingDerivedStartGate.milliseconds(engine.currentTime),
              value <= receipt.identity.durationMs else { return nil }
        return value
    }
    private func saveSample() {
        guard !didFinish, let value = sample() else { return }
        writer.offer(value); lastSave = .now
    }
    private func bindEngine() {
        engine.$videoRoute.receive(on: DispatchQueue.main).sink { [weak self] route in
            guard let self, !didFinish else { return }
            mountSoftwareSurface(route == .software)
            showsPlaybackControls = gate.started && !softwareSurfaceMounted
            #if os(iOS)
            controls.setOwnsTransport(softwareSurfaceMounted)
            #else
            if softwareSurfaceMounted, hud.superview == nil { Self.fill(hud, in: view); view.addSubview(hud); hud.flash() }
            if !softwareSurfaceMounted { hud.removeFromSuperview() }
            #endif
        }.store(in: &cancellables)
        engine.clock.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, !didFinish, gate.started else { return }
            checkLifetime()
            guard !discarded else { return }
            let duration = Double(receipt.identity.durationMs) / 1000
            #if os(iOS)
            controls.update(position: engine.currentTime, duration: duration, paused: engine.state == .paused)
            #else
            hud.update(position: engine.currentTime, duration: duration, paused: engine.state == .paused)
            #endif
            if lastSave.duration(to: .now) >= .seconds(10) { saveSample() }
        }.store(in: &cancellables)
        engine.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self, !didFinish, gate.started else { return }
            switch state {
            case .paused: saveSample()
            case .ended: dismiss(animated: true) // Final save reads actual time, never manufactures the duration.
            case .error: fail()
            default: break
            }
        }.store(in: &cancellables)
    }
    private func toggle() {
        guard gate.started, !didFinish else { return }
        checkLifetime(); guard !discarded else { return }
        engine.togglePlayPause()
    }
    private func seek(by delta: Double) { seek(to: engine.currentTime + delta) }
    private func seek(to seconds: Double) {
        guard gate.started, !didFinish, seconds.isFinite else { return }
        checkLifetime(); guard !discarded else { return }
        seekTask?.cancel()
        let position = min(max(0, seconds), Double(receipt.identity.durationMs) / 1000)
        seekTask = Task { [weak self] in
            guard let self else { return }
            await engine.seek(to: position)
            guard !Task.isCancelled, !didFinish else { return }
            checkLifetime(); guard !discarded else { return }
            saveSample()
        }
    }
    #if os(tvOS)
    override var softwareHUDHasOpenLayer: Bool { softwareSurfaceMounted && hud.isInfoShowing }
    override func closeSoftwareHUDLayer() { hud.setInfo(visible: false) }
    override func streamInfoDidChange(_ info: StreamInfo) { hud.setDetails(info.summary) }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !gate.started || discarded {
            if presses.contains(where: { $0.type == .menu }) { dismiss(animated: true) }
            return
        }
        guard softwareSurfaceMounted, let press = presses.first else { return super.pressesBegan(presses, with: event) }
        switch press.type {
        case .select, .playPause: toggle()
        case .leftArrow: seek(by: -10)
        case .rightArrow: seek(by: 10)
        case .downArrow: hud.setInfo(visible: !hud.isInfoShowing)
        case .upArrow: hud.setInfo(visible: false)
        case .menu: if !hud.isInfoShowing { dismiss(animated: true) }; return
        default: return super.pressesBegan(presses, with: event)
        }
        hud.flash()
    }
    #else
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); if controls.superview === view { view.bringSubviewToFront(controls) } }
    override func streamInfoDidChange(_ info: StreamInfo) { controls.setDetails(info.summary) }
    #endif
    private func fail() {
        guard !didFinish, !discarded else { return }
        discarded = true; gate.close(); writer.retire(); engine.pause()
        PlaybackCoordinator.shared.errorMessage = String(localized: "The original joined recording or start receipt is unavailable. Return and choose playback explicitly.")
        dismiss(animated: true)
    }
    override func finish() {
        guard !didFinish else { return }
        let final = sample()
        didFinish = true; gate.close(); expiryTimer?.invalidate(); expiryTimer = nil
        loadTask?.cancel(); seekTask?.cancel(); cancellables.removeAll()
        #if os(iOS)
        chrome.stop()
        #endif
        settingsHider.stop(); player = nil; mountSoftwareSurface(false)
        engine.stop()
        let ownedWriter = writer!, discard = discarded || !gate.started
        // This task retains the original writer until the actual network resource
        // invalidates. A later player cannot inherit or retarget its final write.
        cleanupTask = Task { await ownedWriter.close(finalPosition: final, discard: discard) }
        PlaybackCoordinator.shared.playerDidClose()
    }
}
