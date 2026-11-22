import Foundation

@MainActor
protocol KidsLiveAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func isCurrent(_ context: SourceActionContext) -> Bool
    func kidsLivePolicy(context: SourceActionContext) async throws -> KidsLivePolicy
    func kidsLiveChannels(context: SourceActionContext) async throws -> [KidsLiveChannel]
    func kidsLiveStart(_ id: String, context: SourceActionContext) async throws -> KidsLiveStartReply
    func keepKidsLive(_ session: String, context: SourceActionContext) async throws
    func stopKidsLive(_ session: String, context: SourceActionContext) async throws
}

extension APIClient: KidsLiveAPI {
    func kidsLivePolicy(context: SourceActionContext) async throws -> KidsLivePolicy {
        try requireSourceContext(context)
        let request = try context.request("GET", path: "/api/users/\(Self.segment(context.profileID))/kids/live-policy")
        let reply = try decoder.decode(KidsLivePolicyReply.self, from: await sendOriginalSourceAction(request))
        try requireSourceContext(context)
        return reply.policy
    }
    func kidsLiveChannels(context: SourceActionContext) async throws -> [KidsLiveChannel] {
        try requireSourceContext(context)
        let reply = try decoder.decode(KidsLiveChannelsReply.self, from: await sendOriginalSourceAction(context.request("GET", path: "/api/live/kids/channels")))
        try requireSourceContext(context)
        return reply.channels
    }
    static func kidsLiveStartRequest(_ id: String, context: SourceActionContext) throws -> URLRequest {
        guard !id.isEmpty else { throw APIError.notReady("Choose a channel again") }
        var request = try context.request("GET", path: "/api/live/kids/hls/start")
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.notReady("The channel address is unavailable")
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "channelId", value: id), URLQueryItem(name: "clientId", value: context.clientID),
            URLQueryItem(name: "target", value: "native")]
        request.url = components.url
        return request
    }
    func kidsLiveStart(_ id: String, context: SourceActionContext) async throws -> KidsLiveStartReply {
        try requireSourceContext(context)
        // No post-response context check here: the owner must observe the actual
        // returned session even after departure and retire that known session.
        let data = try await sendOriginalSourceAction(Self.kidsLiveStartRequest(id, context: context))
        do { return try decoder.decode(KidsLiveStartReply.self, from: data) }
        catch {
            // A malformed programme descriptor may still contain a known real
            // session. Retire only that receipt under its original transport.
            struct Receipt: Decodable { let sessionId: String }
            if let receipt = try? decoder.decode(Receipt.self, from: data), KidsLiveOpened.validSession(receipt.sessionId) {
                let cleanup = Task { try? await self.stopKidsLive(receipt.sessionId, context: context) }
                await cleanup.value
            }
            throw error
        }
    }
    func keepKidsLive(_ session: String, context: SourceActionContext) async throws {
        try requireSourceContext(context)
        guard KidsLiveOpened.validSession(session) else { throw APIError.notReady("Invalid programme session") }
        _ = try await sendOriginalSourceAction(context.request("POST", path: "/api/video/hls/\(Self.segment(session))/keepalive"))
        try requireSourceContext(context)
    }
    func stopKidsLive(_ session: String, context: SourceActionContext) async throws {
        guard KidsLiveOpened.validSession(session) else { throw APIError.notReady("Invalid programme session") }
        // Cleanup keeps its actual creator transport after a profile change.
        _ = try await sendOriginalSourceAction(context.request("POST", path: "/api/video/hls/\(Self.segment(session))/stop"))
    }
}
