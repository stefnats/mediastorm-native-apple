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
    private var operation: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?

    init(prequeueID: String, context: SourceActionContext? = nil, api: any ReleaseReportAPI = APIClient.shared) {
        self.prequeueID = prequeueID
        self.api = api
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
            do {
                let reply = try await api.submitReleaseAction(prequeueID, options: options,
                                                              submission: submission, context: context)
                // A late receipt still owns cleanup, but cannot publish into a
                // closed dialog or whichever profile is now active.
                guard !closed, !Task.isCancelled, api.isCurrent(context) else {
                    if let next = reply.replacement { await cancelKnownReplacement(next.prequeueId) }
                    return
                }
                replacement = reply.replacement
                savedReportID = reply.report?.id
                resumePosition = reply.resumePosition
                alternativeAvailable = reply.partialFailure == nil && reply.replacement?.prequeueId.isEmpty == false
                    && reply.resumePosition.map { $0.isFinite && $0 >= 0 } == true
                message = reply.partialFailure ?? (reply.report == nil
                    ? String(localized: "Alternative prepared. Choose Play Alternative to switch.")
                    : String(localized: "Report saved."))
            } catch {
                // No automatic POST retry: the server may already have saved a
                // report even when its acknowledgement did not reach this device.
                if !closed {
                    outcomeUnknown = true
                    message = String(localized: "The action could not be confirmed. Reopen the dialog before trying again.")
                }
            }
        }
    }

    /// A replacement is transferred only by an explicit Play Alternative press.
    func takeReplacement() -> (id: String, position: Double)? {
        guard !busy, !closed, alternativeAvailable, api.isCurrent(context), let replacement,
              let position = resumePosition, position.isFinite, position >= 0 else { return nil }
        self.replacement = nil
        alternativeAvailable = false
        return (replacement.prequeueId, position)
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
        guard let replacement else { return }
        self.replacement = nil
        alternativeAvailable = false
        await cancelKnownReplacement(replacement.prequeueId)
    }

    private func cancelKnownReplacement(_ id: String) async {
        // Independent of a cancelled POST task; await the actual DELETE task.
        let request = Task { try await api.cancelReleaseReplacement(id, context: context) }
        do { try await request.value }
        catch {
            if !closed, api.isCurrent(context) {
                message = String(localized: "The alternative cancellation could not be confirmed. It was not played.")
            }
        }
    }
}
