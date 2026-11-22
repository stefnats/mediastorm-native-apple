import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class EpisodeAdvanceController: ObservableObject {
    let next: PlaybackRequest?
    let context: SourceActionContext
    private let api: any EpisodeAutoplayAPI
    private let now: () -> Duration
    private let active: () -> Bool
    private let advance: (PlaybackRequest) -> Void
    private let settingsChanged: (EpisodeAutoplaySettings) -> Void
    private let visibility: () -> Void
    private var policy: EpisodeAdvancePolicy
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var revision = 0
    private var closed = false
    private var denied = false
    private var suspended = false
    @Published private(set) var settingsError: String?
    @Published private(set) var loadingSettings = false
    var current: Bool { !closed && !denied && api.isCurrent(context) }
    var visible: Bool { current && policy.visible }
    var seconds: Int? { policy.seconds }
    var paused: Bool { policy.countdownPaused }
    var cancelled: Bool { policy.cancelled }
    var ended: Bool { policy.mediaEnded }
    init(next: PlaybackRequest?, context: SourceActionContext, api: any EpisodeAutoplayAPI = APIClient.shared,
         now: @escaping () -> Duration, active: @escaping () -> Bool = { true }, visibility: @escaping () -> Void = {},
         settingsChanged: @escaping (EpisodeAutoplaySettings) -> Void = { _ in }, advance: @escaping (PlaybackRequest) -> Void) {
        self.next = next; self.context = context; self.api = api; self.now = now; self.active = active; self.visibility = visibility; self.settingsChanged = settingsChanged; self.advance = advance
        policy = EpisodeAdvancePolicy(hasTarget: next?.isEpisode == true && next?.fileOnlyPlayback == false)
    }
    func start(scheduleTimer: Bool = true) {
        guard current, observers.isEmpty, next != nil else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .episodeAutoplayChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { if let value = note.object as? EpisodeAutoplayChange { self?.adopt(value) } }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(true) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(false) }
        })
        if let change = EpisodeAutoplayChanges.latest { adopt(change) }
        loadSettings()
        if scheduleTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }
    func loadSettings() {
        guard current, !loadingSettings else { return }
        let before = revision; loadingSettings = true; settingsError = nil
        task = Task { [weak self] in
            guard let self else { return }; defer { if !closed { loadingSettings = false; task = nil } }
            do {
                try Task.checkCancellation(); guard current else { return }
                let settings = try await api.episodeAutoplay(context)
                try Task.checkCancellation(); guard current else { return }
                objectWillChange.send()
                if before == revision { policy.autoplay = settings.enabled }
                policy.skipCredits = settings.skipCredits
                settingsChanged(settings); tick()
            } catch {
                guard current, !error.isCancellation else { return }
                objectWillChange.send()
                if before == revision {
                    policy.autoplay = nil
                    settingsError = "Autoplay is unavailable. Start the next episode manually or reload the profile choice."
                }
                if [401, 403].contains((error as? APIError)?.statusCode ?? 0) { denied = true; policy.close() }
                visibility()
            }
        }
    }
    private func adopt(_ change: EpisodeAutoplayChange) {
        guard current, change.context == context, change.revision > revision else { return }
        objectWillChange.send(); revision = change.revision; policy.autoplay = change.enabled; tick()
    }
    func observe(credits: Bool, playing: Bool, position: Double, duration: Double, failed: Bool) {
        guard current else { return close() }
        objectWillChange.send(); policy.observe(credits: credits, playing: playing, position: position, duration: duration, failed: failed); tick()
    }
    @discardableResult
    func naturalEnd(position: Double, duration: Double, failed: Bool) -> Bool {
        guard current else { return false }
        objectWillChange.send(); let handled = policy.ended(position: position, duration: duration, failed: failed); tick(); return handled
    }
    func suspend(_ value: Bool) { suspended = value; policy.suspendClock() }
    func tick() {
        guard current else { return close() }
        guard !suspended, active() else { policy.suspendClock(); return }
        let previous = policy.seconds
        if policy.tick(now: now()), let next { objectWillChange.send(); visibility(); advance(next); return }
        if previous != policy.seconds { objectWillChange.send() }
        visibility()
    }
    func pauseCountdown() { guard current else { return }; objectWillChange.send(); policy.togglePause(); visibility() }
    func cancelCountdown() { guard current else { return }; objectWillChange.send(); policy.cancel(); visibility() }
    func startNow() {
        guard current, !suspended, active(), let next, policy.claim() else { return }
        objectWillChange.send(); visibility(); advance(next)
    }
    func close() {
        guard !closed else { return }; closed = true; task?.cancel(); timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        objectWillChange.send(); policy.close(); visibility()
    }
}

extension PlayerViewController {
    func startEpisodeAdvance() {
        guard episodeAdvance == nil, let next = nextEpisode, request.isEpisode, !request.fileOnlyPlayback, !engine.isLive, !playsDownload else { return }
        let context = progressViewer, origin = ContinuousClock.now
        let controller = EpisodeAdvanceController(next: next, context: context,
            now: { origin.duration(to: .now) }, active: { [weak self] in
                guard let self else { return false }; return !didFinish && !isExitingToDetails && !isInBackground && !isBeingDismissed && presentedViewController == nil
            }, visibility: { [weak self] in self?.refreshEpisodeAdvancePanel() }, settingsChanged: { [weak self] settings in
                self?.creditsAutoSkip = settings.skipCredits
                self?.creditsDetectionEnabled = CreditsDetectionSettingsStore.shared.enabled(server: settings.detectCredits)
            }, advance: { [weak self] next in self?.handoffNextEpisode(next) })
        episodeAdvance = controller; controller.start()
    }
    func refreshEpisodeAdvancePanel() {
        guard let model = episodeAdvance, model.visible else {
            if let panel = episodePanel { panel.willMove(toParent: nil); panel.view.removeFromSuperview(); panel.removeFromParent(); episodePanel = nil }
            return
        }
        guard episodePanel == nil else { return }
        let panel = UIHostingController(rootView: EpisodeAdvancePanel(model: model, close: { [weak self] in self?.dismiss(animated: true) }))
        addChild(panel); panel.view.backgroundColor = .clear; panel.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel.view)
        NSLayoutConstraint.activate([panel.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            panel.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32), panel.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.95)])
        panel.didMove(toParent: self); episodePanel = panel
    }
    func handoffNextEpisode(_ next: PlaybackRequest) {
        guard !didFinish, !isAdvancing, !isBeingDismissed, !isExitingToDetails, !isInBackground, presentedViewController == nil,
              let actor = episodeAdvance, actor.current, APIClient.shared.isCurrent(actor.context), PlaybackCoordinator.shared.resolving == nil else { return }
        var next = next; next.speed = playbackSpeed
        let coordinator = PlaybackCoordinator.shared
        guard let ticket = coordinator.prepareNextEpisode(next, context: actor.context) else { return }
        isAdvancing = true; episodeAdvance?.close(); stopCountdown(); progressTimer?.invalidate()
        if !episodeEndReported { reportProgress(ended: true); episodeEndReported = true }
        let context = actor.context
        episodeHandoffTask = Task { [weak self] in
            guard let self else { return }
            try? await progressWriter.stopAndDrain(requireKnownAcknowledgements: false)
            guard !Task.isCancelled, !didFinish, APIClient.shared.isCurrent(context), coordinator.episodeTransitionCurrent(ticket) else { return }
            dismiss(animated: true) { coordinator.deliverNextEpisode(ticket) }
        }
    }
}
