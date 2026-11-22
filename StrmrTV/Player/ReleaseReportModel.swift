import SwiftUI

/// One dialog, one original source and one in-flight action. Acknowledge reports
/// and replacement preparation separately; cancellation never means rollback.
@MainActor
final class ReleaseReportModel: ObservableObject {
    @Published private(set) var options: ReleaseReportOptions?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var savedReportID: String?
    @Published private(set) var replacement: ReleaseReportReply.Replacement?
    @Published private(set) var resumePosition: Double?
    @Published private(set) var alternativeAvailable = false
    @Published private(set) var outcomeUnknown = false
    private(set) var closed = false
    let prequeueID: String
    let context: SourceActionContext
    private let api: any ReleaseReportAPI
    private weak var progressOwner: (any ReleaseReportProgressOwner)?
    private let ownership: ReleaseReplacementOwnership
    private var replacementLease: ReleaseReplacementOwnership.Lease?
    private(set) var wrongContent = false
    private var operation: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?

    init(prequeueID: String, context: SourceActionContext? = nil, api: any ReleaseReportAPI = APIClient.shared,
         progressOwner: (any ReleaseReportProgressOwner)? = nil,
         ownership: ReleaseReplacementOwnership = .shared) {
        self.ownership = ownership
        self.prequeueID = prequeueID
        self.api = api
        self.progressOwner = progressOwner
        self.context = context ?? api.sourceContext()
    }

    func load() {
        guard !busy, !closed else { return }
        busy = true
        operation = Task { [self] in
            defer { busy = false }
            guard !closed, !Task.isCancelled else { return }
            do {
                let value = try await api.releaseReportOptions(prequeueID, context: context)
                guard !closed, !Task.isCancelled, api.isCurrent(context) else { return }
                guard !value.sourceVersion.isEmpty else { throw APIError.notReady("The source version is unavailable") }
                options = value
            } catch {
                if !closed { message = error.localizedDescription }
            }
        }
    }

    func submit(_ submission: ReleaseReportSubmission) {
        guard !busy, !closed, !outcomeUnknown, savedReportID == nil, replacement == nil, let options else { return }
        guard api.isCurrent(context) else { message = String(localized: "Profile or connection changed. Reopen this dialog."); return }
        do { _ = try submission.body(options: options, clientID: context.clientID) }
        catch { message = error.localizedDescription; return }
        busy = true
        message = nil
        operation = Task { [self] in
            defer { busy = false }
            guard !closed, !Task.isCancelled else { return }
            var actionSent = false
            var acknowledged = false
            var reservation: ReleaseReplacementOwnership.Request?
            defer { if let reservation { ownership.finish(reservation) } }
            do {
                if submission.reason?.permitsHistoryReset == true {
                    guard let progressOwner else {
                        throw APIError.notReady("The active player's progress must be stopped before reporting wrong content")
                    }
                    wrongContent = true
                    try await progressOwner.prepareWrongContentReport(resetHistory: submission.resetHistory)
                    try Task.checkCancellation()
                    guard !closed, api.isCurrent(context) else { return }
                }
                if submission.retry {
                    reservation = try await ownership.begin(original: prequeueID, context: context)
                    try Task.checkCancellation()
                    guard !closed, api.isCurrent(context) else { return }
                }
                // A UI cancellation must not cancel URLSession.data(for:) after
                // POST admission and discard an observable late replacement ID.
                // This one owned task is joined by operation and close cleanup;
                // its transport has a real 30-second resource timeout, no replay.
                let mutation = Task { [self] in
                    guard !closed, api.isCurrent(context) else { throw CancellationError() }
                    actionSent = true
                    return try await api.submitReleaseAction(prequeueID, options: options,
                                                             submission: submission, context: context)
                }
                let reply = try await mutation.value
                acknowledged = true
                let lease: ReleaseReplacementOwnership.Lease?
                if let next = reply.replacement, let reservation {
                    lease = try ownership.adopt(next.prequeueId, request: reservation, api: api, context: context)
                } else { lease = nil }
                if let reservation { ownership.finish(reservation) }
                // A late receipt still owns cleanup, but cannot publish into a
                // closed dialog or whichever profile is now active.
                guard !closed, !Task.isCancelled, api.isCurrent(context) else {
                    if let lease { await release(lease) }
                    return
                }
                replacementLease = lease
                replacement = reply.replacement
                savedReportID = reply.report?.id
                resumePosition = reply.resumePosition
                message = reply.partialFailure ?? (reply.report == nil
                    ? String(localized: "Preparing alternative while the current player stays open…")
                    : String(localized: "Report saved."))
                if reply.partialFailure == nil, let lease {
                    let deadline = Date().addingTimeInterval(180)
                    while Date() < deadline {
                        let ready = try await api.releaseReplacementStatus(lease.id, context: context)
                        try Task.checkCancellation()
                        guard !closed, api.isCurrent(context) else { return }
                        if ready.status == "ready", ready.streamPath?.isEmpty == false {
                            alternativeAvailable = true
                            message = String(localized: "Alternative ready. Choose where to start and press Play Alternative.")
                            return
                        }
                        if ready.status == "failed" || ready.status == "expired" {
                            throw APIError.notReady(ready.error ?? "The alternative is unavailable. The current player was kept open.")
                        }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    throw APIError.notReady("The alternative is not ready yet. The current player was kept open.")
                }
            } catch {
                // No automatic POST retry: the server may already have saved a
                // report even when its acknowledgement did not reach this device.
                if !closed {
                    outcomeUnknown = actionSent && !acknowledged
                    message = outcomeUnknown ? String(localized: "The action could not be confirmed. Reopen the dialog before trying again.")
                        : error.localizedDescription
                }
            }
        }
    }

    /// A replacement is transferred only by an explicit Play Alternative press.
    struct Transfer {
        let lease: ReleaseReplacementOwnership.Lease
        let position: Double
        var id: String { lease.id }
    }

    func takeReplacement() -> Transfer? {
        guard !busy, !closed, alternativeAvailable, api.isCurrent(context), let lease = replacementLease else { return nil }
        replacementLease = nil
        replacement = nil
        alternativeAvailable = false
        return Transfer(lease: lease, position: resumePosition ?? 0)
    }

    var cleanupNeedsRetry: Bool { ownership.needsCleanupRetry(original: prequeueID, context: context) }

    func retryCleanup() {
        guard !busy, !closed, api.isCurrent(context) else { return }
        busy = true
        operation = Task { [self] in
            defer { busy = false }
            do {
                try await ownership.retryCleanup(original: prequeueID, context: context)
                message = String(localized: "Alternative cancellation confirmed. You can try preparing an alternative again.")
            } catch { message = error.localizedDescription }
        }
    }

    func undoReport() {
        guard !busy, !closed, let id = savedReportID, api.isCurrent(context) else { return }
        busy = true
        operation = Task { [self] in
            defer { busy = false }
            guard !closed, !Task.isCancelled else { return }
            do {
                try await api.deleteReleaseReport(id, context: context)
                guard !closed, !Task.isCancelled, api.isCurrent(context) else { return }
                savedReportID = nil
                message = String(localized: "Report removed. Any history reset is not restored.")
            } catch {
                if !closed { message = String(localized: "Report removal could not be confirmed. Reload before trying again.") }
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        let pending = operation
        pending?.cancel()
        // The cleanup task owns the actual in-flight completion and DELETE. It
        // cannot be cancelled by a disappearing SwiftUI view or join itself.
        cleanup = Task { [self] in
            await pending?.value
            await discardReplacement()
        }
    }

    func waitForOperation() async { await operation?.value }
    func waitForCleanup() async { await cleanup?.value }

    private func discardReplacement() async {
        guard let lease = replacementLease else { return }
        replacementLease = nil
        replacement = nil
        alternativeAvailable = false
        await release(lease)
    }

    private func release(_ lease: ReleaseReplacementOwnership.Lease) async {
        // Cancellation of the dialog never cancels the actual owned DELETE.
        let task = Task { try await lease.release() }
        do { try await task.value }
        catch { if !closed { message = error.localizedDescription } }
    }
}
