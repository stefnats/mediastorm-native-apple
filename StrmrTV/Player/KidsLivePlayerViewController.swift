import AetherEngine
import Combine
import UIKit

/// One actual admitted open, with independently joined cleanup. Closing the UI
/// never cancels away a late session receipt or adopts a replacement profile.
@MainActor
final class KidsLivePlaybackOperation {
    let context: SourceActionContext
    private let api: any KidsLiveAPI
    private let now: () -> Duration
    private var opening: Task<KidsLiveStartReply, Error>?
    private var cleanup: Task<Void, Never>?
    private(set) var closed = false

    init(context: SourceActionContext, api: any KidsLiveAPI, now: @escaping () -> Duration) {
        self.context = context; self.api = api; self.now = now
    }
    func open(channelID: String) async throws -> KidsLiveOpened {
        guard opening == nil, !closed, api.isCurrent(context) else { throw CancellationError() }
        let started = now()
        let work = Task { [api, context] in try await api.kidsLiveStart(channelID, context: context) }
        opening = work
        do {
            let reply = try await work.value
            guard !closed, !Task.isCancelled, api.isCurrent(context) else { throw CancellationError() }
            return try KidsLiveOpened.validate(reply, context: context, requestedAt: started, now: now())
        } catch {
            close()
            throw error
        }
    }
    func isCurrent() -> Bool { !closed && api.isCurrent(context) }
    func close(after pendingKeepalive: Task<Void, Never>? = nil) {
        guard !closed else { return }
        closed = true
        let work = opening
        cleanup = Task { [api, context] in
            await pendingKeepalive?.value
            guard let reply = try? await work?.value, KidsLiveOpened.validSession(reply.sessionId) else { return }
            // One bounded stop; an unknown acknowledgement is not replayed.
            try? await api.stopKidsLive(reply.sessionId, context: context)
        }
    }
    func waitForCleanup() async { await cleanup?.value }
}

/// Independent of engine load and keepalive responses; its deadline never moves.
@MainActor
final class KidsLiveProgrammeClock {
    private let deadline: Duration
    private let now: () -> Duration
    private let current: () -> Bool
    private let ended: () -> Void
    private var stopped = false
    init(deadline: Duration, now: @escaping () -> Duration, current: @escaping () -> Bool, ended: @escaping () -> Void) {
        self.deadline = deadline; self.now = now; self.current = current; self.ended = ended
    }
    func check() -> Bool {
        if !stopped, !current() || now() >= deadline { stopped = true; ended() }
        return !stopped
    }
    func watch() async {
        while check() {
            do { try await Task.sleep(for: min(.milliseconds(250), deadline - now())) }
            catch { return }
        }
    }
}

/// A separate programme player: no adult direct fallback, source retry, seek,
/// catch-up, Cast or multiscreen entry can be inherited from LivePlayer.
final class KidsLivePlayerViewController: EnginePlayerViewController {
    private let channel: KidsLiveChannel
    private let api: any KidsLiveAPI
    private let operation: KidsLivePlaybackOperation
    private let now: () -> Duration
    private let onError: (String) -> Void
    private var loading: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var closed = false

    static func present(_ channel: KidsLiveChannel, context: SourceActionContext, onError: @escaping (String) -> Void) {
        guard channel.selectable, APIClient.shared.isCurrent(context), let engine = PlaybackCoordinator.shared.sharedEngine,
              !AppSession.shared.hasProtectedPlaybackPresentation else { return }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top else { return }
        let origin = ContinuousClock.now
        top.present(Self(engine: engine, channel: channel, context: context, api: APIClient.shared,
            now: { origin.duration(to: .now) }, onError: onError), animated: true)
    }

    init(engine: AetherEngine, channel: KidsLiveChannel, context: SourceActionContext, api: any KidsLiveAPI,
         now: @escaping () -> Duration, onError: @escaping (String) -> Void) {
        self.channel = channel; self.api = api; self.now = now; self.onError = onError
        operation = KidsLivePlaybackOperation(context: context, api: api, now: now)
        super.init(engine: engine, logCategory: "kids-live")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        requiresLinearPlayback = true
        showsPlaybackControls = false
        setInfoPanel(title: channel.programme?.title ?? channel.name, subtitle: channel.name,
                     description: channel.programme?.claim)
        engine.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self, !closed else { return }
            if case .ended = state { stopPlayback() }
            if case let .error(message) = state { stopPlayback(message) }
        }.store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard loading == nil, !closed else { return }
        loading = Task { [self] in
            do {
                let opened = try await operation.open(channelID: channel.id)
                guard !closed else { return }
                // This task stays live while load()/play() suspends, including
                // background/PiP. Keepalive can never change the original limit.
                let clock = KidsLiveProgrammeClock(deadline: opened.deadline, now: now,
                    current: { [weak self] in self?.operation.isCurrent() == true },
                    ended: { [weak self] in self?.stopPlayback() })
                watch = Task { await clock.watch() }
                keepalive = Task { [self] in
                    while !closed {
                        do {
                            try await Task.sleep(for: .seconds(10))
                            guard !closed, operation.isCurrent() else { return }
                            try await api.keepKidsLive(opened.sessionID, context: operation.context)
                        } catch {
                            if !closed, !Task.isCancelled { stopPlayback(error.localizedDescription) }
                            return
                        }
                    }
                }
                var options = baseLoadOptions()
                options.httpHeaders = opened.headers
                options.isLive = true
                options.nativeRemoteHLS = true
                options.liveJoinProfile = .fastZap
                _ = try await engine.load(url: opened.url, options: options)
                guard !closed, operation.isCurrent(), now() < opened.deadline else { stopPlayback(); return }
                engine.play()
            } catch {
                if !closed { stopPlayback(error is CancellationError ? nil : error.localizedDescription) }
            }
        }
    }

    #if os(tvOS)
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { stopPlayback(); return }
        super.pressesBegan(presses, with: event)
    }
    #endif

    private func stopPlayback(_ message: String? = nil) {
        guard !closed else { return }
        finish()
        dismiss(animated: true) { [onError] in if let message { onError(message) } }
    }

    override func finish() {
        guard !closed else { return }
        closed = true
        watch?.cancel(); keepalive?.cancel(); loading?.cancel()
        engine.stop()
        let pendingKeepalive = keepalive
        operation.close(after: pendingKeepalive)
        cleanup = Task { [operation] in
            await pendingKeepalive?.value
            await operation.waitForCleanup()
        }
    }
}
