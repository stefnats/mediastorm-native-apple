import AetherEngine
import Foundation
import UIKit

@MainActor
struct WatchRoomPrepared {
    let target: WatchRoomTarget
    let context: SourceActionContext
    let status: PrequeueStatus
    let request: URLRequest
    var path: String { status.streamPath! }
    var tracks: TrackPreferences { TrackPreferences.overridden(status) ?? TrackPreferences(status) }
}

@MainActor
protocol WatchRoomSourceAPI: WatchRoomsAPI {
    func roomLocalPreference(_ id: String, context: SourceActionContext) async throws -> ContentLocalPreference
}
extension APIClient: WatchRoomSourceAPI {
    func roomLocalPreference(_ id: String, context: SourceActionContext) async throws -> ContentLocalPreference {
        try await contentLocalPreference(id,context:context)
    }
}

/// Each viewer resolves a normal source with their own languages and original
/// credentials. An initial prequeue has no generic DELETE/cancellation endpoint.
@MainActor
final class WatchRoomPreparation {
    let context: SourceActionContext
    let transport: WatchRoomTransport
    private let api: any WatchRoomSourceAPI
    init(context: SourceActionContext, api: any WatchRoomSourceAPI = APIClient.shared) {
        self.context = context; self.api = api; transport = WatchRoomTransport(context:context,api:api)
    }
    private func check() throws {
        try Task.checkCancellation()
        guard transport.current() else { throw CancellationError() }
    }
    static func body(_ target: WatchRoomTarget, context: SourceActionContext, automaticLibrary: Bool) -> [String:Any] {
        var body: [String:Any] = ["titleId":target.title.titleID,"titleName":target.title.name,
            "mediaType":target.title.isMovie ? "movie" : "series","userId":context.profileID,
            "clientId":context.clientID,"reason":"details","skipHLS":true]
        body["imdbId"] = target.title.imdbID; body["tmdbId"] = target.title.tmdbID; body["tvdbId"] = target.title.tvdbID
        body["year"] = target.title.year
        body["seasonNumber"] = target.season; body["episodeNumber"] = target.episode
        return ContentLocalPreference.prequeueBody(body,supported:automaticLibrary)
    }
    static func validate(_ status: PrequeueStatus, id: String, target: WatchRoomTarget) throws {
        guard status.prequeueId == id, status.status == "ready", status.streamPath?.isEmpty == false else { throw WatchRoomError.unavailable }
        if let season = target.season {
            guard status.targetEpisode?.seasonNumber == season, status.targetEpisode?.episodeNumber == target.episode else { throw WatchRoomError.unavailable }
        } else if status.targetEpisode != nil { throw WatchRoomError.unavailable }
    }
    static func mediaRequest(_ path: String, target: WatchRoomTarget, context: SourceActionContext) throws -> URLRequest {
        var request = try context.request("GET",path:"/api/video/stream")
        guard let url = request.url, var parts = URLComponents(url:url,resolvingAgainstBaseURL:false) else { throw WatchRoomError.unavailable }
        var metadata = target.playback.streamMetadata(path:path)
        metadata["path"] = path; metadata["transmux"] = "0"; metadata["clientId"] = context.clientID
        parts.queryItems = (parts.queryItems ?? []) + metadata.sorted{$0.key < $1.key}.map { URLQueryItem(name:$0.key,value:$0.value) }
        request.url = parts.url
        guard request.url != nil else { throw WatchRoomError.unavailable }
        return request
    }
    func prepare(_ target: WatchRoomTarget) async throws -> WatchRoomPrepared {
        try check()
        let local = try await api.roomLocalPreference(target.title.titleID,context:context)
        try check()
        let request = try context.request("POST",path:"/api/playback/prequeue",body:Self.body(target,context:context,automaticLibrary:local.supported))
        let raw = try await transport.send(request)
        let start = try JSONDecoder().decode(PrequeueStartResponse.self,from:raw)
        guard !start.prequeueId.isEmpty, start.prequeueId.utf8.count <= 128 else { throw WatchRoomError.unavailable }
        try check()
        let deadline = ContinuousClock.now.advanced(by:.seconds(180))
        while ContinuousClock.now < deadline {
            try check()
            let poll = try context.request("GET",path:"/api/playback/prequeue/\(APIClient.segment(start.prequeueId))")
            let raw = try await transport.send(poll)
            try check()
            let status = try JSONDecoder().decode(PrequeueStatus.self,from:raw)
            if status.status == "ready" {
                try Self.validate(status,id:start.prequeueId,target:target)
                // Existing automatic-library eligibility rejects combined files
                // server-side. Also reject any explicit file-only descriptor.
                if let fields = try JSONSerialization.jsonObject(with:raw) as? [String:Any],
                   fields["progressScope"] as? String == "file" || fields["fileOnlyPlayback"] as? Bool == true ||
                    (fields["combinedEpisodes"] as? [Any])?.isEmpty == false { throw WatchRoomError.unavailable }
                return WatchRoomPrepared(target:target,context:context,status:status,
                    request:try Self.mediaRequest(status.streamPath!,target:target,context:context))
            }
            if ["failed","expired","cancelled"].contains(status.status) { throw APIError.notReady(status.error ?? "The room source is unavailable") }
            try await Task.sleep(for:.milliseconds(750))
        }
        throw WatchRoomError.unavailable
    }
    func closeAndDrain() async { await transport.stopAndDrain() }
}

/// The actual controller consumes these SDK-facing closures. Ready is sent only
/// after a real load/finite duration/verified seek; remote apply never writes state.
@MainActor
final class WatchRoomEngineGate {
    let session: WatchRoomSession
    private let now: () -> ContinuousClock.Instant
    private var closed = false
    private(set) var loaded = false
    init(session: WatchRoomSession, now: @escaping () -> ContinuousClock.Instant = { .now }) { self.session = session; self.now = now }
    func close() { closed = true }
    func check() throws {
        try Task.checkCancellation()
        guard !closed, session.current(), session.joined, !session.uncertain else { throw WatchRoomError.unavailable }
    }
    static func compatible(actual: Double, expected: Double) throws {
        guard actual.isFinite, actual > 0, actual <= 86_400, expected.isFinite, expected >= 0,
              expected == 0 || abs(actual-expected) <= 10 else { throw WatchRoomError.unavailable }
    }
    func start(expectedDuration: Double, load: () async throws -> Void, duration: () -> Double, position: () -> Double,
               seek: (Double) async -> Void, pause: () -> Void,
               wait: () async throws -> Void = { try await Task.sleep(for:.milliseconds(50)) }) async throws {
        try check(); try await load(); pause(); try check()
        let deadline = now().advanced(by:.seconds(30))
        while duration() == 0 { try check(); guard now() < deadline else { throw WatchRoomError.unavailable }; try await wait() }
        try Self.compatible(actual:duration(),expected:expectedDuration)
        try Self.compatible(actual:duration(),expected:session.room.duration)
        let desired = session.observation.position(now:now())
        guard desired.isFinite, desired >= 0, desired <= duration() else { throw WatchRoomError.unavailable }
        await seek(desired); try check()
        while !position().isFinite || abs(position()-desired) > 1 {
            try check(); guard now() < deadline else { throw WatchRoomError.unavailable }; try await wait()
        }
        loaded = true
        while session.busy { try check(); guard now() < deadline else { throw WatchRoomError.unavailable }; try await wait() }
        guard await session.ready(true) else { throw WatchRoomError.unavailable }
        try check()
    }
    @discardableResult
    func apply(_ original: WatchRoomObservation, duration: () -> Double, position: () -> Double,
               seek: (Double) async -> Void, pause: () -> Void, play: () -> Void) async throws -> Bool {
        try check()
        guard loaded else { return false }
        let room = original.room
        try Self.compatible(actual:duration(),expected:room.duration)
        let desired = original.position(now:now())
        guard desired.isFinite, desired >= 0, desired <= duration(), position().isFinite else { pause(); throw WatchRoomError.unavailable }
        if room.status != "playing" || room.waitingForReady || abs(position()-desired) > 1 { pause() }
        if abs(position()-desired) > 1 {
            await seek(desired); try check()
            guard abs(position()-desired) <= 1 else { throw WatchRoomError.unavailable }
        }
        guard session.room.revision == room.revision, session.room.status == room.status,
              session.room.waitingForReady == room.waitingForReady else { return false }
        if room.waitingForReady, session.room.member(session.context)?.ready != true, !session.busy {
            _ = await session.ready(true)
            try check()
        }
        if session.room.status == "playing", !session.room.waitingForReady { play() } else { pause() }
        return true
    }
}

@MainActor
enum WatchRoomPlayback {
    private static weak var active: WatchRoomPlayerViewController?
    static func play(_ session: WatchRoomSession) throws {
        guard active == nil, PlaybackCoordinator.shared.resolving == nil, session.current(), session.joined else { throw WatchRoomError.unavailable }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var presenter = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        guard let presenter, !(presenter is EnginePlayerViewController) else { throw WatchRoomError.unavailable }
        // The original room owns its engine, so a forced close's late SDK load
        // cannot stop or retarget the next ordinary player's shared engine.
        let engine = try AetherEngine()
        engine.deactivatesAudioSessionOnStop = false
        try session.assignPlayer()
        let player = WatchRoomPlayerViewController(engine:engine,session:session)
        active = player
        presenter.present(player,animated:true)
    }
    static func finished(_ player: WatchRoomPlayerViewController) { if active === player { active = nil } }
}
