import Foundation

@MainActor
protocol ReleaseReportAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func isCurrent(_ context: SourceActionContext) -> Bool
    func releaseReportOptions(_ id: String, context: SourceActionContext) async throws -> ReleaseReportOptions
    func submitReleaseAction(_ id: String, options: ReleaseReportOptions, submission: ReleaseReportSubmission,
                             context: SourceActionContext) async throws -> ReleaseReportReply
    func releaseReplacementStatus(_ id: String, context: SourceActionContext) async throws -> PrequeueStatus
    func cancelReleaseReplacement(_ id: String, context: SourceActionContext) async throws
    func deleteReleaseReport(_ id: String, context: SourceActionContext) async throws
}

extension APIClient: ReleaseReportAPI {
    func sourceContext() -> SourceActionContext { SourceActionContext(self) }
    func isCurrent(_ context: SourceActionContext) -> Bool { context == sourceContext() }

    func releaseReportOptions(_ id: String, context: SourceActionContext) async throws -> ReleaseReportOptions {
        try requireSourceContext(context)
        let request = try context.request("GET", path: "/api/playback/prequeue/\(Self.segment(id))/report")
        let data = try await sendOriginalSourceAction(request)
        try requireSourceContext(context)
        return try decoder.decode(ReleaseReportOptions.self, from: data)
    }

    func submitReleaseAction(_ id: String, options: ReleaseReportOptions, submission: ReleaseReportSubmission,
                             context: SourceActionContext) async throws -> ReleaseReportReply {
        try requireSourceContext(context)
        let path = "/api/playback/prequeue/\(Self.segment(id))/\(submission.reason == nil ? "retry" : "report")"
        let request = try context.request("POST", path: path,
                                          body: submission.body(options: options, clientID: context.clientID))
        // Decode an acknowledged replacement even if the viewer left meanwhile:
        // the dialog owner must cancel that exact replacement, never start another.
        let data = try await sendOriginalSourceAction(request)
        let reply = try decoder.decode(ReleaseReportReply.self, from: data)
        if submission.reason != nil, reply.report?.id.isEmpty != false {
            throw APIError.notReady("The report outcome could not be confirmed. Reopen the dialog; do not resubmit automatically.")
        }
        if submission.retry, reply.partialFailure == nil,
           reply.replacement?.prequeueId.isEmpty != false {
            throw APIError.notReady("The alternative outcome could not be confirmed. Reopen the dialog.")
        }
        return reply
    }

    func releaseReplacementStatus(_ id: String, context: SourceActionContext) async throws -> PrequeueStatus {
        try requireSourceContext(context)
        let request = try context.request("GET", path: "/api/playback/prequeue/\(Self.segment(id))")
        let data = try await sendOriginalSourceAction(request)
        try requireSourceContext(context)
        return try decoder.decode(PrequeueStatus.self, from: data)
    }

    func cancelReleaseReplacement(_ id: String, context: SourceActionContext) async throws {
        // Cleanup uses only the original server/session/profile and never refreshes
        // or adopts whichever account happens to be active now.
        let request = try context.request("DELETE", path: "/api/playback/prequeue/\(Self.segment(id))/retry")
        _ = try await sendOriginalSourceAction(request)
    }

    func deleteReleaseReport(_ id: String, context: SourceActionContext) async throws {
        try requireSourceContext(context)
        let request = try context.request("DELETE", path: "/api/playback/bad-streams/\(Self.segment(id))")
        _ = try await sendOriginalSourceAction(request)
        try requireSourceContext(context)
    }

    func requireSourceContext(_ context: SourceActionContext) throws {
        try Task.checkCancellation()
        guard isCurrent(context) else { throw APIError.notReady("Profile or connection changed. Reopen this dialog.") }
    }
}
