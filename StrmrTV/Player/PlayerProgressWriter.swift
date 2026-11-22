import UIKit

@MainActor
protocol PlayerProgressAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func reportOriginalProgress(_ body: [String: Any], context: SourceActionContext) async -> ProgressReply?
}

extension APIClient: PlayerProgressAPI {
    func reportOriginalProgress(_ body: [String: Any], context: SourceActionContext) async -> ProgressReply? {
        guard let request = try? context.request("POST",
            path: "/api/users/\(Self.segment(context.profileID))/history/progress", body: body),
              let data = try? await sendOriginalSourceAction(request) else { return nil }
        return try? decoder.decode(ProgressReply.self, from: data)
    }
}

@MainActor
protocol PlayerProgressObserver: AnyObject {
    func progressDidReply(_ reply: ProgressReply, ended: Bool)
}

@MainActor
protocol ReleaseReportProgressOwner: AnyObject {
    func prepareWrongContentReport(resetHistory: Bool) async throws
}

/// Owns the actual progress requests, including their background-task cleanup.
/// Closing admission never cancels an HTTP request and pretends its write rolled
/// back. Reset requires known acknowledgements for all previously admitted writes.
@MainActor
final class PlayerProgressWriter {
    private(set) var accepting = true
    private(set) var hasUnconfirmedWrite = false
    private let viewer: SourceActionContext
    private let api: any PlayerProgressAPI
    private weak var observer: (any PlayerProgressObserver)?
    private var writes: [UUID: Task<Void, Never>] = [:]
    private var completion: Task<Result<PostPlayCompletion, Error>, Never>?

    init(viewer: SourceActionContext, api: any PlayerProgressAPI = APIClient.shared,
         observer: (any PlayerProgressObserver)? = nil) {
        self.viewer = viewer
        self.api = api
        self.observer = observer
    }

    @discardableResult
    func submit(_ body: [String: Any], ended: Bool) -> Bool {
        let current = api.sourceContext()
        guard accepting, viewer.sameViewer(as: current) else { return false }
        let id = UUID()
        writes[id] = Task { [self] in
            let background = UIApplication.shared.beginBackgroundTask(withName: "progress")
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                writes[id] = nil
            }
            // Capture the actual current session at admission, retaining the
            // original viewer. Neither refresh nor a later profile can retarget it.
            let reply = await api.reportOriginalProgress(body, context: current)
            if reply == nil { hasUnconfirmedWrite = true }
            if accepting, viewer.sameViewer(as: api.sourceContext()), let reply {
                observer?.progressDidReply(reply, ended: ended)
            }
        }
        return true
    }

    func stopAndDrain(requireKnownAcknowledgements: Bool) async throws {
        // Permanent for this old source, including its eventual finish write.
        accepting = false
        let pending = Array(writes.values)
        for write in pending { await write.value }
        if let completion { _ = await completion.value }
        if requireKnownAcknowledgements && hasUnconfirmedWrite {
            throw APIError.notReady("A previous progress write is unconfirmed. History cannot safely be reset from this playback.")
        }
    }

    /// Completion is a final ordered write after every earlier admitted request.
    /// An unknown acknowledgement is not retried or converted into a watched mark.
    func complete(_ body: [String: Any]) async throws -> PostPlayCompletion {
        try await beginCompletion(body).value.get()
    }
    func beginCompletion(_ body: [String: Any]) -> Task<Result<PostPlayCompletion, Error>, Never> {
        if let completion { return completion }
        let current = api.sourceContext()
        guard accepting, viewer.sameViewer(as: current), body["playbackEnded"] as? Bool == true,
              let kind = body["mediaType"] as? String, ["movie", "episode"].contains(kind) else { return Task { .failure(PostPlayFailure.completion) } }
        accepting = false
        let pending = Array(writes.values)
        let task = Task<Result<PostPlayCompletion, Error>, Never> { [self] in
            for write in pending { await write.value }
            guard !hasUnconfirmedWrite, viewer.sameViewer(as: api.sourceContext()) else { return .failure(PostPlayFailure.completion) }
            let background = UIApplication.shared.beginBackgroundTask(withName: "completed-progress")
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            guard let reply = await api.reportOriginalProgress(body, context: current), reply.mediaType == kind,
                  let item = reply.itemId, !item.isEmpty, item.utf8.count <= 512,
                  !item.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                hasUnconfirmedWrite = true; return .failure(PostPlayFailure.completion)
            }
            return .success(PostPlayCompletion(context: current, itemID: item, mediaType: kind))
        }
        completion = task
        return task
    }

    func waitForWrites() async {
        let pending = Array(writes.values)
        for write in pending { await write.value }
        if let completion { _ = await completion.value }
    }
}
