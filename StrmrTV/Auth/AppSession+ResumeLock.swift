import UIKit

extension AppSession {
    func observeBackgroundForResumeLock() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeGate.backgrounded() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyResumeLock() }
        }
    }

    func refreshResumeLockSetting() {
        struct Display: Decodable { let alwaysShowProfileSelector: Bool? }
        struct Settings: Decodable { let display: Display? }
        let owner = resumeOwner
        Task {
            guard let settings: Settings = try? await api.send("GET", "/api/settings", promptOnLock: false, timeout: 10),
                  owner == resumeOwner else { return }
            alwaysShowProfileSelector = settings.display?.alwaysShowProfileSelector ?? true
        }
    }

    var resumeOwner: ResumePINOwner {
        ResumePINOwner(context: api.sourceContext(), activation: resumeActivation, session: api.token)
    }

    /// Unlike the existing VOD-only coordinator predicate, this covers every
    /// actual protected player host without changing unrelated playback policy.
    static func isProtectedPlaybackType(_ type: UIViewController.Type) -> Bool {
        type.isSubclass(of: EnginePlayerViewController.self) || type.isSubclass(of: MultiscreenHostController.self)
    }

    var hasProtectedPlaybackPresentation: Bool {
        if PlaybackCoordinator.shared.resolving != nil { return true }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            var current = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            while let controller = current {
                if Self.isProtectedPlaybackType(type(of: controller)) { return true }
                current = controller.presentedViewController
            }
        }
        return false
    }

    private func applyResumeLock() {
        guard phase == .ready, let current = profile else { return }
        let action = resumeGate.foreground(owner: resumeOwner, requiresPIN: current.requiresPin,
            player: hasProtectedPlaybackPresentation, automatic: current.id == autoProfileID,
            showPicker: alwaysShowProfileSelector, profileCount: profiles.count)
        applyResumeAction(action)
        refreshResumeLockSetting()
    }

    /// UIKit dismissal and both roots call this after their synchronous lifecycle
    /// work. A source handoff or another presented player retains the obligation.
    func playbackReturnedToBrowsing() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, phase == .ready, let current = profile else { return }
            let action = resumeGate.browsing(owner: resumeOwner, requiresPIN: current.requiresPin,
                                             player: hasProtectedPlaybackPresentation)
            applyResumeAction(action)
        }
    }

    private func applyResumeAction(_ action: DeferredResumeGate.Action) {
        protectedBrowsingBlocked = resumeGate.blocked
        switch action {
        case .none, .deferred: return
        case .picker:
            profilePickRequired = profile?.requiresPin == true
            Task { await switchProfile() }
        case let .pin(ticket):
            profilePickRequired = true
            Task { [weak self] in
                guard let self else { return }
                let unlocked = await unlockLockedProfile(ticket.owner.context.profileID)
                if unlocked, resumeGate.complete(ticket, owner: resumeOwner) {
                    profilePickRequired = false
                } else {
                    resumeGate.release(ticket)
                }
                protectedBrowsingBlocked = resumeGate.blocked
            }
        }
    }
}
