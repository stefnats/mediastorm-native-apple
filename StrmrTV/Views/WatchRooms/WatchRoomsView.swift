import SwiftUI

/// Root navigation may present this same lobby without a title. Joining and
/// starting local playback are separate, explicit actions.
struct WatchRoomsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: WatchRoomsModel
    @ObservedObject private var departures = WatchRoomDepartures.shared
    private let target: WatchRoomTarget?
    @State private var selected: Set<String> = []
    init(context: SourceActionContext, target: WatchRoomTarget? = nil) {
        _model = StateObject(wrappedValue:WatchRoomsModel(context:context)); self.target = target
    }
    var body: some View {
        NavigationStack {
            List {
                if let session = model.session {
                    WatchRoomLobby(session:session) {
                        model.session = nil
                        Task { await model.reload() }
                    }
                } else {
                    if let target {
                        Section("Create a room for \(target.title.name)") {
                            if let season = target.season, let episode = target.episode { Text(String(format:"S%02dE%02d",season,episode)) }
                            ForEach(model.profiles.filter { $0.id != model.context.profileID }) { profile in
                                Button {
                                    if selected.contains(profile.id) { selected.remove(profile.id) }
                                    else if selected.count < 64 { selected.insert(profile.id) }
                                } label: { Label(profile.name,systemImage:selected.contains(profile.id) ? "checkmark.circle.fill" : "circle") }
                            }
                            Button("Create room") { model.create(target,invitees:selected.sorted()) }
                                .disabled(model.busy || model.creationUnknown || !model.current())
                            Text("Each participant prepares their own source, audio and subtitles. No playback starts from an invitation.")
                                .font(.footnote)
                        }
                    }
                    Section("Profile invitations and rooms") {
                        ForEach(model.rooms) { room in
                            Button { model.open(room) } label: {
                                VStack(alignment:.leading) { Text(room.title); Text("\(room.creatorName) · \(room.status)").font(.caption) }
                            }.disabled(model.busy || !model.current())
                        }
                        if model.rooms.isEmpty { Text("No current rooms") }
                    }
                    Section("Account invitations") {
                        ForEach(model.invites.filter { $0.status == "pending" }) { invite in
                            VStack(alignment:.leading,spacing:8) {
                                Text(invite.title ?? String(localized:"Room invitation"))
                                if let creator = invite.creatorName { Text(creator).font(.caption) }
                                HStack {
                                    Button("Accept") { model.accept(invite) }
                                    Button("Decline",role:.destructive) { Task { await model.decline(invite) } }
                                }.disabled(model.busy || !model.current())
                            }
                        }
                    }
                    Button("Read current invitations") { Task { await model.reload() } }.disabled(model.busy || !model.current())
                }
                let pending = departures.pending(model.context)
                if !pending.isEmpty {
                    Section("Unconfirmed room actions") {
                        ForEach(pending) { owner in
                            VStack(alignment:.leading,spacing:8) {
                                if owner.roomID != nil {
                                    Text("The original departure has not been confirmed.")
                                    Button("Retry original departure") { Task { _ = await owner.depart(retry:true) } }.disabled(owner.busy)
                                } else {
                                    Text("Room admission was not confirmed and its identifier was not returned. Read existing rooms; do not create another room automatically.")
                                }
                            }
                        }
                    }
                }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                if model.busy { ProgressView() }
            }
            .navigationTitle("Watch Together")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task { await model.reload() }
        .onDisappear { Task { await model.close() } }
    }
}

private struct WatchRoomLobby: View {
    @ObservedObject var session: WatchRoomSession
    let leave: () -> Void
    @State private var username = ""
    @State private var error: String?
    @State private var departing = false
    var body: some View {
        Section(session.room.title) {
            Text("\(session.room.creatorName) · \(session.room.status)")
            if session.room.waitingForReady { Text("Waiting for participant readiness") }
            ForEach(session.room.members) { member in
                Text("\(member.name) · \(member.joined ? (member.ready ? String(localized:"Ready") : String(localized:"Preparing")) : String(localized:"Invited"))")
            }
            if !session.joined {
                Button("Join room") { Task { await session.join() } }
                    .disabled(session.busy || session.uncertain || !session.current())
            } else {
                Button("Prepare and open local player") {
                    do { try WatchRoomPlayback.play(session) } catch { self.error = error.localizedDescription }
                }.disabled(session.busy || session.uncertain || session.transferred || !session.current())
                Text("Readiness is reported only after your own player has loaded and reached the room position. Play, pause and seek in that player update the room.")
                    .font(.footnote)
            }
            Button("Read current room") { Task { await session.refresh() } }.disabled(session.busy || !session.current())
            if session.room.creatorProfileId == session.context.profileID {
                TextField("Account username",text:$username)
                Button("Invite account") { Task { await session.inviteAccount(username) } }
                    .disabled(session.busy || session.uncertain || !session.current() || username.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Button("Read account invitations") { Task { await session.refreshInvites() } }.disabled(session.busy || !session.current())
                ForEach(session.accountInvites) { invite in
                    VStack(alignment:.leading) {
                        Text("\(invite.inviteeUsername ?? String(localized:"Account")) · \(invite.status)")
                        if invite.status == "pending" {
                            Button("Revoke invitation",role:.destructive) { Task { await session.revoke(invite) } }.disabled(session.busy || !session.current())
                        }
                    }
                }
                Button("End room",role:.destructive) { close(end:true) }.disabled(departing || session.transferred)
            }
            Button(session.closed && !session.cleanupConfirmed ? "Retry original departure" : "Leave room",role:.destructive) {
                close(end:false)
            }.disabled(departing || (session.transferred && !session.closed))
            if session.closed, session.cleanupConfirmed { Button("Back to rooms",action:leave) }
            if let error { Text(error).foregroundStyle(.secondary) }
            if let message = session.message { Text(message).foregroundStyle(.secondary) }
        }
        .task { session.startPolling() }
    }
    private func close(end: Bool) {
        guard !departing else { return }; departing = true
        Task {
            let confirmed = session.closed ? await session.retryDeparture() : await session.close(end:end)
            departing = false
            if confirmed { leave() }
        }
    }
}
