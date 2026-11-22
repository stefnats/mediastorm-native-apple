import Foundation
import UIKit

struct LiveRecordingChallenge: Decodable {
    let confirmationToken: String
    let recordingCount: Int
    let expiresInSeconds: Int
    static func from(_ error: Error) -> Self? {
        guard let error = error as? APIError, error.statusCode == 409, error.code == "LIVE_RECORDING_CONFIRMATION_REQUIRED",
              let body = error.failure?.body.data(using: .utf8), let value = try? JSONDecoder().decode(Self.self, from: body),
              value.confirmationToken.range(of: "^[a-f0-9]{48}$", options: .regularExpression) != nil,
              value.recordingCount > 0, (1...30).contains(value.expiresInSeconds) else { return nil }
        return value
    }
}

/// One explicit channel intent, including its automatic retunes. No global pool.
@MainActor
final class LivePlaybackAttempt {
    let id: String
    let context: SourceActionContext
    private let permitsTakeover: Bool
    private let current: () -> Bool
    private let now: () -> Duration
    private var input: String?
    private var opening = false
    private(set) var admitted = false
    private(set) var uncertain = false
    private var stopped = false
    private static let terminalCodes: Set<String> = ["LIVE_STREAM_TAKEN_OVER", "LIVE_RECORDING_CONFIRMATION_REQUIRED",
        "LIVE_RECORDING_CONFIRMATION_EXPIRED", "LIVE_TAKEOVER_PERMISSION_CHANGED", "LIVE_TAKEOVER_STOP_FAILED",
        "LIVE_TAKEOVER_PENDING_CLOSE", "LIVE_STREAM_LIMIT_REACHED"]

    init(context: SourceActionContext, permitsTakeover: Bool = true, id: String = UUID().uuidString,
         now: (() -> Duration)? = nil, current: @escaping () -> Bool) {
        self.context = context; self.permitsTakeover = permitsTakeover; self.id = id; self.current = current
        let origin = ContinuousClock.now
        self.now = now ?? { origin.duration(to: .now) }
    }
    func blocksRetry(_ error: Error) -> Bool {
        uncertain || stopped || error is CancellationError || (error as? APIError)?.code.map { Self.terminalCodes.contains($0) } == true
    }
    func close() { stopped = true }
    func stopUnconfirmed() { uncertain = true }
    func isCurrent() -> Bool { !stopped && current() }
    var canAutomaticallyRetry: Bool { !stopped && !uncertain }

    /// Preference/identity lookup is preparation under the original viewer,
    /// never a place to capture replacement credentials after an await.
    func prepare(_ preference: () async -> Bool) async throws -> Bool {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let value = await preference()
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        return value
    }

    func open(_ channel: LiveChannel, automaticIntent: Bool = false,
              confirm: @escaping (LiveRecordingChallenge, Duration) async -> Bool,
              fetch: @escaping (String, String?, Bool) async throws -> LiveStart,
              retire: @escaping (LiveStart) async throws -> Void) async throws -> LiveStart {
        guard !opening, !uncertain, !Task.isCancelled, isCurrent() else { throw CancellationError() }
        let fingerprint = "\(channel.sourceId?.utf8.count ?? 0):\(channel.sourceId ?? ""):\(channel.id.utf8.count):\(channel.id):\(channel.url)"
        guard input == nil || input == fingerprint else { throw CancellationError() }
        input = fingerprint; opening = true
        defer { opening = false }
        let requested = now()
        let automatic = admitted || !permitsTakeover || automaticIntent
        do {
            let reply: LiveStart
            do {
                reply = try await request(fetch, token: nil, automatic: automatic)
            } catch {
                guard !automatic, let challenge = LiveRecordingChallenge.from(error), isCurrent(), !Task.isCancelled else { throw error }
                let deadline = requested + .seconds(challenge.expiresInSeconds)
                guard now() < deadline, await confirm(challenge, deadline), now() < deadline,
                      isCurrent(), !Task.isCancelled else { throw CancellationError() }
                // Exactly one confirmed retry. The token is not retained in this
                // attempt, and a later error cannot renew its prompt or privilege.
                reply = try await request(fetch, token: challenge.confirmationToken, automatic: false)
            }
            admitted = true
            guard isCurrent(), !Task.isCancelled else {
                let cleanup = Task { try await retire(reply) }
                do { try await cleanup.value } catch { uncertain = true }
                throw CancellationError()
            }
            return reply
        } catch {
            if !(error is CancellationError), (error as? APIError)?.failure == nil { uncertain = true }
            throw error
        }
    }
    private func request(_ fetch: @escaping (String, String?, Bool) async throws -> LiveStart,
                         token: String?, automatic: Bool) async throws -> LiveStart {
        // UI cancellation does not cancel the actual admitted HTTP request.
        let work = Task {
            guard self.isCurrent() else { throw CancellationError() }
            return try await fetch(id, token, automatic)
        }
        return try await work.value
    }

    func confirmRecording(_ challenge: LiveRecordingChallenge, deadline: Duration) async -> Bool {
        await LiveRecordingConsent.ask(challenge, deadline: deadline, now: now, current: { self.isCurrent() })
    }
}

/// A cancel-first, single-use prompt over the real requesting TV/phone host.
@MainActor
private final class LiveRecordingConsent {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?
    private weak var alert: UIAlertController?

    static func ask(_ challenge: LiveRecordingChallenge, deadline: Duration, now: @escaping () -> Duration,
                    current: @escaping () -> Bool) async -> Bool {
        let request = LiveRecordingConsent()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { request.continuation = $0; request.present(challenge, deadline: deadline, now: now, current: current) }
        } onCancel: {
            Task { @MainActor in request.finish(false) }
        }
    }
    private func present(_ challenge: LiveRecordingChallenge, deadline: Duration, now: @escaping () -> Duration,
                         current: @escaping () -> Bool) {
        guard current(), now() < deadline else { finish(false); return }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top, !(top is UIAlertController) else { finish(false); return }
        let alert = UIAlertController(title: String(localized: "Interrupt recording?"),
            message: "\(challenge.recordingCount) recording(s) will stop. Captured parts are kept as incomplete.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Keep recording"), style: .cancel) { [self] _ in finish(false) })
        alert.addAction(UIAlertAction(title: String(localized: "Stop recording and play"), style: .destructive) { [self] _ in
            finish(current() && now() < deadline)
        })
        alert.preferredAction = alert.actions.first
        self.alert = alert
        top.present(alert, animated: true)
        timer = Task { [self] in
            while continuation != nil {
                if !current() || now() >= deadline || alert.presentingViewController == nil { finish(false); return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
    private func finish(_ accepted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); timer = nil
        alert?.dismiss(animated: true)
        continuation.resume(returning: accepted)
    }
}

/// The actual multiscreen producer/stop seam, injectable without changing the
/// original deterministic MultiscreenTransport adapters or receiver protocols.
@MainActor
protocol LiveMultiscreenAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func isCurrent(_ context: SourceActionContext) -> Bool
    func startLiveHLS(_ channel: LiveChannel, attempt: LivePlaybackAttempt) async throws -> (sessionID: String?, url: URL?)
    func stopLiveSessionStrict(_ session: String, context: SourceActionContext?) async throws
}
