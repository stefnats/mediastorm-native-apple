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
        if requireKnownAcknowledgements && hasUnconfirmedWrite {
            throw APIError.notReady("A previous progress write is unconfirmed. History cannot safely be reset from this playback.")
        }
    }

    func waitForWrites() async {
        let pending = Array(writes.values)
        for write in pending { await write.value }
    }
}
