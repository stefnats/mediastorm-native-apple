import Foundation

enum WatchRoomWire {
    @MainActor static func path(_ context: SourceActionContext, room: String? = nil) -> String {
        let base = "/api/users/\(APIClient.segment(context.profileID))/watch-rooms"
        return room.map { base+"/"+APIClient.segment($0) } ?? base
    }
    @MainActor static func request(_ context: SourceActionContext, method: String, room: String? = nil,
                                    suffix: String = "", body: [String:Any]? = nil) throws -> URLRequest {
        try context.request(method,path:path(context,room:room)+suffix,body:body)
    }
    static var capabilities: [String:Any] { ["nativePlayback":true,"stateSync":true,"protocolVersion":1] }
    static func createBody(_ target: WatchRoomTarget, context: SourceActionContext, invitees: [String]) throws -> [String:Any] {
        guard invitees.count <= 64, Set(invitees).count == invitees.count, invitees.allSatisfy({!$0.isEmpty}) else { throw WatchRoomError.unavailable }
        var body: [String:Any] = ["title":target.title.name,"mediaType":target.title.isMovie ? "movie" : "episode","itemId":target.itemID,
            "params":target.params,"inviteeProfileIds":invitees,"clientId":context.clientID,"capabilities":capabilities]
        body["posterUrl"] = target.title.posterURL; body["backdropUrl"] = target.title.backdropURL
        return body
    }
    static func stateBody(_ room: WatchRoom, paused: Bool, position: Double, duration: Double) throws -> [String:Any] {
        guard room.revision >= 0, room.revision < Int64.max, position.isFinite, position >= 0,
              duration.isFinite, duration > 0, position <= duration else { throw WatchRoomError.unavailable }
        return ["status":paused ? "paused" : "playing","position":position,"duration":duration,"expectedRevision":room.revision]
    }
}

@MainActor
protocol WatchRoomsAPI: AnyObject {
    func isCurrent(_ context: SourceActionContext) -> Bool
    func performWatchRoomRequest(_ request: URLRequest) async throws -> Data
}

extension APIClient: WatchRoomsAPI {
    func performWatchRoomRequest(_ request: URLRequest) async throws -> Data { try await sendOriginalSourceAction(request) }
}

/// Serial original-request owner. Cancellation closes admission but never loses
/// the actual response of an already admitted Create/Join/Accept mutation.
@MainActor
final class WatchRoomTransport {
    let context: SourceActionContext
    let api: any WatchRoomsAPI
    private var tail: Task<Void,Never>?
    private var closed = false
    private(set) var admitted = 0
    init(context: SourceActionContext, api: any WatchRoomsAPI = APIClient.shared) { self.context = context; self.api = api }
    func current() -> Bool { !closed && api.isCurrent(context) }
    func send(_ request: URLRequest, onAdmitted: (@MainActor () -> Void)? = nil) async throws -> Data {
        guard current(), !Task.isCancelled else { throw CancellationError() }
        let previous = tail
        let work = Task { [self] in
            await previous?.value
            guard current() else { throw CancellationError() }
            admitted += 1
            onAdmitted?()
            return try await api.performWatchRoomRequest(request)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
    func stopAndDrain() async { closed = true; await tail?.value }
    func cleanup(_ room: String, end: Bool) async -> Bool {
        await stopAndDrain()
        let original = context, api = api
        let work = Task { () -> Bool in
            do {
                let request = try WatchRoomWire.request(original,method:"POST",room:room,suffix:end ? "/end" : "/leave")
                _ = try await api.performWatchRoomRequest(request)
                return true
            } catch { return false }
        }
        return await work.value
    }
    func decodeRoom(_ raw: Data, expectedID: String? = nil, expectedTarget: WatchRoomTarget? = nil) throws -> WatchRoom {
        let room = try JSONDecoder().decode(WatchRoom.self,from:raw)
        try room.validate()
        let target = try WatchRoomTarget(room:room)
        guard expectedID == nil || room.id == expectedID,
              expectedTarget == nil || target == expectedTarget else { throw WatchRoomError.unavailable }
        return room
    }
    static func acknowledgedID(_ raw: Data) -> String? {
        guard let fields = try? JSONSerialization.jsonObject(with:raw) as? [String:Any],
              let id = fields["id"] as? String, UUID(uuidString:id) != nil else { return nil }
        return id
    }
}
