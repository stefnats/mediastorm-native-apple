import Combine
import Foundation

@MainActor
final class WatchRoomsModel: ObservableObject {
    let context: SourceActionContext
    let transport: WatchRoomTransport
    @Published private(set) var rooms: [WatchRoom] = []
    @Published private(set) var invites: [WatchRoomAccountInvite] = []
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var creationUnknown = false
    @Published var session: WatchRoomSession?
    private var operation: Task<Void,Never>?
    private var closed = false
    let departures: WatchRoomDepartures
    init(context: SourceActionContext, api: any WatchRoomsAPI = APIClient.shared, departures: WatchRoomDepartures = .shared) {
        self.context = context; transport = WatchRoomTransport(context:context,api:api); self.departures = departures
    }
    func current() -> Bool { !closed && transport.current() }
    func reload() async {
        guard current(), !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let roomData = try await transport.send(WatchRoomWire.request(context,method:"GET",suffix:"/invitations"))
            let next = try JSONDecoder().decode([WatchRoom].self,from:roomData)
            for room in next { try room.validate() }
            let inviteRequest = try context.request("GET",path:"/api/watch-room-account-invitations")
            let inviteData = try await transport.send(inviteRequest)
            let invitations = try JSONDecoder().decode([WatchRoomAccountInvite].self,from:inviteData)
            for invitation in invitations { try invitation.validate() }
            let profileData = try await transport.send(context.request("GET",path:"/api/users"))
            let profiles = try JSONDecoder().decode([Profile].self,from:profileData)
            guard current(), !Task.isCancelled else { return }
            rooms = next; invites = invitations; self.profiles = profiles
        } catch { if current(), !Task.isCancelled { message = error.localizedDescription } }
    }
    func open(_ room: WatchRoom) {
        guard current(), !busy, session == nil else { return }
        do { session = try WatchRoomSession(room:room,context:context,api:transport.api,departures:departures) }
        catch { message = error.localizedDescription }
    }
    func create(_ target: WatchRoomTarget, invitees: [String]) {
        guard current(), !busy, !creationUnknown, session == nil else { return }
        let request: URLRequest
        do { request = try WatchRoomWire.request(context,method:"POST",body:WatchRoomWire.createBody(target,context:context,invitees:invitees)) }
        catch { message = error.localizedDescription; return }
        admit(request,created:true,target:target)
    }
    func accept(_ invite: WatchRoomAccountInvite) {
        guard current(), !busy, session == nil, invite.status == "pending" else { return }
        do {
            try invite.validate()
            let request = try context.request("POST",path:"/api/users/\(APIClient.segment(context.profileID))/watch-room-account-invitations/\(APIClient.segment(invite.id))/accept")
            admit(request,created:false,target:nil,expectedID:invite.roomId)
        } catch { message = error.localizedDescription }
    }
    private func admit(_ request: URLRequest, created: Bool, target: WatchRoomTarget?, expectedID: String? = nil) {
        let ownership: WatchRoomOwnership
        do {
            ownership = try departures.reserve(context:context,api:transport.api)
            if let expectedID { try ownership.bind(expectedID,end:false) }
        } catch { message = error.localizedDescription; return }
        busy = true; message = nil
        operation = Task { [self] in
            defer { busy = false; operation = nil }
            let admitted = transport.admitted
            do {
                let data = try await transport.send(request)
                if expectedID == nil, let id = WatchRoomTransport.acknowledgedID(data) { try ownership.bind(id,end:created) }
                let room = try transport.decodeRoom(data,expectedID:expectedID,expectedTarget:target)
                let owner = try WatchRoomSession(room:room,context:context,api:transport.api,cleanup:created ? .end : .leave,
                    ownership:ownership,departures:departures)
                if !current() || Task.isCancelled {
                    _ = await owner.close(); return
                }
                session = owner
            } catch {
                if transport.admitted == admitted { ownership.releaseUnadmitted() }
                else if ownership.roomID != nil { _ = await ownership.depart() }
                else { ownership.unknownWithoutLocator() }
                if current() { creationUnknown = true; message = String(localized:"Room admission was not confirmed. Read your invitations and existing rooms; do not repeat the creation or acceptance automatically.") }
            }
        }
    }
    func waitForOperation() async { await operation?.value }
    func decline(_ invite: WatchRoomAccountInvite) async {
        guard current(), !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try invite.validate()
            let request = try context.request("POST",path:"/api/watch-room-account-invitations/\(APIClient.segment(invite.id))/decline")
            _ = try await transport.send(request)
            guard current() else { return }
            invites.removeAll { $0.id == invite.id }
        } catch { if current() { message = error.localizedDescription } }
    }
    func close() async {
        guard !closed else { return }
        closed = true
        await transport.stopAndDrain()
        await operation?.value
        if let session, !session.transferred { _ = await session.close() }
        session = nil
    }
}
