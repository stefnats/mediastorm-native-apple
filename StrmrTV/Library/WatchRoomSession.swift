import Combine
import Foundation

/// Retains only known original departures, never a playback grant. Reservations
/// precede admission so a failed late cleanup cannot overflow and be forgotten.
@MainActor
final class WatchRoomDepartures: ObservableObject {
    static let shared = WatchRoomDepartures()
    @Published private(set) var entries: [WatchRoomOwnership] = []
    func reserve(context: SourceActionContext, api: any WatchRoomsAPI) throws -> WatchRoomOwnership {
        guard entries.count < 64 else { throw WatchRoomError.unavailable }
        let owner = WatchRoomOwnership(context:context,api:api,ledger:self)
        entries.append(owner)
        return owner
    }
    fileprivate func release(_ owner: WatchRoomOwnership) { entries.removeAll { $0 === owner } }
    fileprivate func changed() { objectWillChange.send() }
    func pending(_ context: SourceActionContext) -> [WatchRoomOwnership] {
        entries.filter { $0.failed && $0.context.sameViewer(as:context) }
    }
}

@MainActor
final class WatchRoomOwnership: ObservableObject, Identifiable {
    let id = UUID()
    let context: SourceActionContext
    private(set) var roomID: String?
    private var end = false
    @Published private(set) var failed = false
    @Published private(set) var busy = false
    private let transport: WatchRoomTransport
    private weak var ledger: WatchRoomDepartures?
    private var closing: Task<Bool,Never>?
    fileprivate init(context: SourceActionContext, api: any WatchRoomsAPI, ledger: WatchRoomDepartures) {
        self.context = context; self.ledger = ledger; transport = WatchRoomTransport(context:context,api:api)
    }
    func bind(_ id: String, end: Bool) throws {
        guard UUID(uuidString:id) != nil, roomID == nil || roomID == id else { throw WatchRoomError.unavailable }
        roomID = id; self.end = self.end || end
    }
    func releaseUnadmitted() { ledger?.release(self) }
    func unknownWithoutLocator() { failed = true; ledger?.changed() }
    func depart(retry: Bool = false) async -> Bool {
        if let closing {
            let previous = await closing.value
            if previous || !retry { return previous }
            self.closing = nil
        }
        guard let roomID else { return false }
        busy = true
        let work = Task { [self] in
            let result = await transport.cleanup(roomID,end:end)
            failed = !result; busy = false
            if result { ledger?.release(self) } else { ledger?.changed() }
            return result
        }
        closing = work
        return await work.value
    }
}

/// Original room membership and serialized request owner, transferred once to
/// the actual player. Remote observations never call sendState themselves.
@MainActor
final class WatchRoomSession: ObservableObject, Identifiable {
    enum Cleanup: Equatable { case none, leave, end }
    let id: String
    let context: SourceActionContext
    let target: WatchRoomTarget
    let transport: WatchRoomTransport
    @Published private(set) var observation: WatchRoomObservation
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var uncertain = false
    @Published private(set) var closed = false
    @Published private(set) var cleanupConfirmed = false
    @Published private(set) var accountInvites: [WatchRoomAccountInvite] = []
    private(set) var transferred = false
    var buffering = true
    private var cleanup: Cleanup
    private var ownership: WatchRoomOwnership?
    private let departures: WatchRoomDepartures
    private var polling: Task<Void,Never>?
    private var closing: Task<Bool,Never>?
    var room: WatchRoom { observation.room }
    var joined: Bool {
        let member = room.member(context)
        return member?.joined == true && member?.clientId == context.clientID && member?.capabilities.nativePlayback == true && member?.capabilities.stateSync == true && (member?.capabilities.protocolVersion ?? 0) >= 1
    }
    init(room: WatchRoom, context: SourceActionContext, api: any WatchRoomsAPI = APIClient.shared, cleanup: Cleanup = .none,
         ownership: WatchRoomOwnership? = nil, departures: WatchRoomDepartures = .shared) throws {
        try room.validate()
        guard room.member(context) != nil else { throw WatchRoomError.unavailable }
        id = room.id; self.context = context; target = try WatchRoomTarget(room:room)
        observation = WatchRoomObservation(room); transport = WatchRoomTransport(context:context,api:api); self.cleanup = cleanup
        self.departures = departures; self.ownership = ownership
        if cleanup != .none {
            if self.ownership == nil { self.ownership = try departures.reserve(context:context,api:api) }
            try self.ownership?.bind(room.id,end:cleanup == .end)
        }
    }
    func current() -> Bool { !closed && transport.current() && room.status != "ended" }
    func assignPlayer() throws {
        guard current(), joined, !transferred, !uncertain else { throw WatchRoomError.unavailable }
        if ownership == nil { ownership = try departures.reserve(context:context,api:transport.api) }
        try ownership?.bind(id,end:cleanup == .end)
        if cleanup == .none { cleanup = .leave }
        transferred = true
    }
    private func adopt(_ raw: Data) throws {
        let next = try transport.decodeRoom(raw,expectedID:id,expectedTarget:target)
        guard next.member(context) != nil, next.revision >= room.revision else { throw WatchRoomError.unavailable }
        guard !closed, transport.current() else { throw CancellationError() }
        observation = WatchRoomObservation(next)
    }
    func refresh(explicit: Bool = true) async {
        guard !closed, !busy, explicit || !uncertain else { return }
        busy = true
        defer { busy = false }
        do {
            try adopt(await transport.send(WatchRoomWire.request(context,method:"GET",room:id)))
            uncertain = false; message = nil
        } catch {
            if !closed { message = error.localizedDescription; uncertain = true }
        }
    }
    func join() async {
        guard current(), !busy, !uncertain else { return }
        busy = true
        defer { busy = false }
        do {
            if ownership == nil { ownership = try departures.reserve(context:context,api:transport.api) }
            try ownership?.bind(id,end:cleanup == .end)
            let request = try WatchRoomWire.request(context,method:"POST",room:id,suffix:"/join",
                body:["clientId":context.clientID,"capabilities":WatchRoomWire.capabilities])
            let raw = try await transport.send(request,onAdmitted:{
                if self.cleanup == .none { self.cleanup = .leave }
            })
            // The join may have committed before close/profile departure.
            try adopt(raw)
            guard joined else { throw WatchRoomError.unavailable }
            message = nil
        } catch { if !closed { uncertain = true; message = error.localizedDescription } }
    }
    @discardableResult
    func ready(_ ready: Bool) async -> Bool {
        guard current(), joined, !busy, !uncertain else { return false }
        busy = true
        defer { busy = false }
        do {
            let request = try WatchRoomWire.request(context,method:"POST",room:id,suffix:"/ready",body:["ready":ready])
            try adopt(await transport.send(request)); message = nil
            return room.member(context)?.ready == ready
        } catch { if !closed { uncertain = true; message = error.localizedDescription }; return false }
    }
    private func readInvites() async throws {
        let request = try WatchRoomWire.request(context,method:"GET",room:id,suffix:"/account-invites")
        let raw = try await transport.send(request)
        let values = try JSONDecoder().decode([WatchRoomAccountInvite].self,from:raw)
        for value in values { try value.validate(); guard value.roomId == id else { throw WatchRoomError.unavailable } }
        guard current() else { throw CancellationError() }
        accountInvites = values
    }
    func refreshInvites() async {
        guard current(), !busy, room.creatorProfileId == context.profileID else { return }
        busy = true
        defer { busy = false }
        do { try await readInvites() } catch { if !closed { message = error.localizedDescription } }
    }
    func inviteAccount(_ username: String) async {
        let username = username.trimmingCharacters(in:.whitespacesAndNewlines)
        guard current(), !busy, !uncertain, room.creatorProfileId == context.profileID, !username.isEmpty, username.utf8.count <= 256 else { return }
        busy = true
        defer { busy = false }
        do {
            let request = try WatchRoomWire.request(context,method:"POST",room:id,suffix:"/account-invites",body:["username":username])
            let raw = try await transport.send(request)
            let invite = try JSONDecoder().decode(WatchRoomAccountInvite.self,from:raw)
            try invite.validate(); guard invite.roomId == id, current() else { throw WatchRoomError.unavailable }
            try await readInvites()
        } catch { if !closed { uncertain = true; message = error.localizedDescription } }
    }
    func revoke(_ invite: WatchRoomAccountInvite) async {
        guard current(), !busy, !uncertain, room.creatorProfileId == context.profileID, invite.roomId == id else { return }
        busy = true
        defer { busy = false }
        do {
            try invite.validate()
            let request = try WatchRoomWire.request(context,method:"DELETE",room:id,suffix:"/account-invites/\(APIClient.segment(invite.id))")
            _ = try await transport.send(request)
            try await readInvites()
        } catch { if !closed { uncertain = true; message = error.localizedDescription } }
    }
    @discardableResult
    func sendState(paused: Bool, position: Double, duration: Double) async -> Bool {
        guard current(), joined, !busy, !uncertain else { return false }
        busy = true
        defer { busy = false }
        do {
            let body = try WatchRoomWire.stateBody(room,paused:paused,position:position,duration:duration)
            let request = try WatchRoomWire.request(context,method:"POST",room:id,suffix:"/state",body:body)
            try adopt(await transport.send(request)); message = nil
            return true
        } catch {
            if (error as? APIError)?.statusCode == 409, !closed {
                // Read the winning state once; never resend the rejected write.
                do { try adopt(await transport.send(WatchRoomWire.request(context,method:"GET",room:id))) }
                catch { uncertain = true }
            } else { uncertain = true }
            if !closed { message = error.localizedDescription }
            return false
        }
    }
    func startPolling(wait: @escaping () async throws -> Void = { try await Task.sleep(for:.seconds(1)) }) {
        guard polling == nil, !closed else { return }
        polling = Task { [self] in
            var ticks = 0
            while !closed, !Task.isCancelled {
                do { try await wait() } catch { return }
                guard !closed, !Task.isCancelled else { return }
                if busy || uncertain { continue }
                await refresh(explicit:false)
                ticks += 1
                if ticks % 10 == 0, current(), joined, !busy, !uncertain {
                    do {
                        let request = try WatchRoomWire.request(context,method:"POST",room:id,suffix:"/heartbeat",
                            body:["clientId":context.clientID,"buffering":buffering])
                        _ = try await transport.send(request)
                    } catch { if !closed { uncertain = true; message = error.localizedDescription } }
                }
            }
        }
    }
    @discardableResult
    func close(end: Bool = false) async -> Bool {
        if let closing { return await closing.value }
        if end {
            do {
                if ownership == nil { ownership = try departures.reserve(context:context,api:transport.api) }
                try ownership?.bind(id,end:true); cleanup = .end
            } catch { message = error.localizedDescription; return false }
        }
        closed = true
        let pendingPoll = polling; pendingPoll?.cancel(); polling = nil
        let work = Task { [self] in
            await transport.stopAndDrain()
            await pendingPoll?.value
            let confirmed: Bool
            if cleanup == .none { ownership?.releaseUnadmitted(); confirmed = true }
            else { confirmed = await ownership?.depart() ?? false }
            cleanupConfirmed = confirmed
            if !confirmed { message = String(localized:"The original room departure is unconfirmed. Retry departure explicitly; no new room action was sent.") }
            return confirmed
        }
        closing = work
        return await work.value
    }
    func retryDeparture() async -> Bool {
        guard closed, !cleanupConfirmed, let closing else { return cleanupConfirmed }
        _ = await closing.value
        let result = await ownership?.depart(retry:true) ?? false
        cleanupConfirmed = result
        return result
    }
}
