import Foundation

struct EpisodeAutoplaySettings {
    let enabled: Bool
    let skipCredits: Bool
    let detectCredits: Bool
    struct Playback: Decodable {
        let nextEpisodeAutoPlay: Bool?
        let creditsAutoSkip: Bool?
        let creditsDetection: Bool?
        let creditsDetectionEnabled: Bool?
    }
    struct Profile: Decodable { let playback: Playback }
    static func decode(_ data: Data, device: Data? = nil) throws -> Self {
        let user = try JSONDecoder().decode(Profile.self, from: data).playback
        let device = device.flatMap { try? JSONDecoder().decode(Playback.self, from: $0) }
        return Self(enabled: user.nextEpisodeAutoPlay ?? true,
            skipCredits: device?.creditsAutoSkip ?? device?.creditsDetection ?? user.creditsAutoSkip ?? user.creditsDetection ?? false,
            detectCredits: device?.creditsDetectionEnabled ?? user.creditsDetectionEnabled ?? false)
    }
}

@MainActor
protocol EpisodeAutoplayAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func isCurrent(_ context: SourceActionContext) -> Bool
    func episodeAutoplay(_ context: SourceActionContext) async throws -> EpisodeAutoplaySettings
    func saveEpisodeAutoplay(_ enabled: Bool, context: SourceActionContext) async throws -> Bool
}

extension APIClient: EpisodeAutoplayAPI {
    static func episodeAutoplayRequest(_ context: SourceActionContext, value: Bool? = nil) throws -> URLRequest {
        var request = try context.request(value == nil ? "GET" : "PATCH",
            path: "/api/users/\(segment(context.profileID))/settings" + (value == nil ? "" : "/skipping"),
            body: value.map { ["nextEpisode": $0] })
        request.timeoutInterval = 5; return request
    }
    private func episodeAutoplayData(_ request: URLRequest, context: SourceActionContext) async throws -> Data {
        try requireSourceContext(context); try Task.checkCancellation()
        let data = try await sendOriginalSourceAction(request)
        try Task.checkCancellation(); try requireSourceContext(context)
        guard data.count <= 1_048_576 else { throw APIError.notReady("Playback settings could not be read") }; return data
    }
    func episodeAutoplay(_ context: SourceActionContext) async throws -> EpisodeAutoplaySettings {
        let user = try await episodeAutoplayData(Self.episodeAutoplayRequest(context), context: context)
        // Validate the required profile object before the optional device read.
        _ = try EpisodeAutoplaySettings.decode(user)
        var device: Data?
        do {
            var request = try context.request("GET", path: "/api/clients/\(Self.segment(context.clientID))/settings")
            guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PostPlayFailure.invalid }
            parts.queryItems = (parts.queryItems ?? []) + [.init(name: "userId", value: context.profileID)]; request.url = parts.url; request.timeoutInterval = 5
            device = try await episodeAutoplayData(request, context: context)
        } catch {
            if error.isCancellation || !isCurrent(context) || [401, 403].contains((error as? APIError)?.statusCode ?? 0) { throw error }
            // A missing legacy device override is not a profile autoplay choice.
        }
        try requireSourceContext(context); return try EpisodeAutoplaySettings.decode(user, device: device)
    }
    static func episodeAutoplayConfirmation(_ data: Data, expected: Bool) throws -> Bool {
        struct Reply: Decodable { let nextEpisode: Bool }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.nextEpisode == expected else { throw APIError.notReady("The profile choice was not confirmed") }; return reply.nextEpisode
    }
    func saveEpisodeAutoplay(_ enabled: Bool, context: SourceActionContext) async throws -> Bool {
        let data = try await episodeAutoplayData(Self.episodeAutoplayRequest(context, value: enabled), context: context)
        return try Self.episodeAutoplayConfirmation(data, expected: enabled)
    }
}

struct EpisodeAutoplayChange {
    let context: SourceActionContext
    let enabled: Bool
    let revision: Int
}
extension Notification.Name { static let episodeAutoplayChanged = Notification.Name("episodeAutoplayChanged") }
@MainActor
enum EpisodeAutoplayChanges {
    private static var revision = 0
    private(set) static var latest: EpisodeAutoplayChange?
    static func saved(_ value: Bool, context: SourceActionContext) {
        revision += 1; let change = EpisodeAutoplayChange(context: context, enabled: value, revision: revision)
        latest = change; NotificationCenter.default.post(name: .episodeAutoplayChanged, object: change)
    }
}
