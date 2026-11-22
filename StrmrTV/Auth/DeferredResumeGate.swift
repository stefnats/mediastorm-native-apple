import Foundation

/// Process-local identity for a return check, never server authorization.
struct ResumePINOwner: Equatable {
    let context: SourceActionContext
    let activation: UUID
    private let session: String?

    init(context: SourceActionContext, activation: UUID, session: String?) {
        self.context = context; self.activation = activation; self.session = session
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.activation == rhs.activation && lhs.session == rhs.session && lhs.context.sameViewer(as: rhs.context)
    }
}

/// A player retains its local obligation; only browsing asks for the existing PIN.
/// Continuous time includes sleep and does not follow wall-clock adjustments.
@MainActor
final class DeferredResumeGate {
    struct Ticket: Equatable {
        let id: UUID
        let owner: ResumePINOwner
    }
    enum Action: Equatable {
        case none, deferred, picker
        case pin(Ticket)
    }
    private let now: () -> Duration
    private var since: Duration?
    private var pending: Ticket?
    private var active: Ticket?
    var blocked: Bool { pending != nil }

    init(now: @escaping () -> Duration) { self.now = now }

    convenience init() {
        let origin = ContinuousClock.now
        self.init(now: { origin.duration(to: .now) })
    }

    func backgrounded() {
        if since == nil { since = now() }
    }

    func foreground(owner: ResumePINOwner, requiresPIN: Bool, player: Bool,
                    automatic: Bool, showPicker: Bool, profileCount: Int) -> Action {
        let away = since.map { max(.zero, now() - $0) }
        since = nil
        reconcile(owner: owner, requiresPIN: requiresPIN)
        if requiresPIN, let away, away >= .seconds(300), pending == nil {
            pending = Ticket(id: UUID(), owner: owner)
        }
        if player { return blocked ? .deferred : .none }
        if !automatic, showPicker, profileCount > 1, let away, away > .seconds(2) {
            return .picker
        }
        return browsing(owner: owner, requiresPIN: requiresPIN, player: false)
    }

    func browsing(owner: ResumePINOwner, requiresPIN: Bool, player: Bool) -> Action {
        reconcile(owner: owner, requiresPIN: requiresPIN)
        guard let pending else { return .none }
        if player { return .deferred }
        guard active != pending else { return .none }
        active = pending
        return .pin(pending)
    }

    func current(_ ticket: Ticket, owner: ResumePINOwner) -> Bool {
        pending == ticket && active == ticket && ticket.owner == owner
    }

    @discardableResult
    func complete(_ ticket: Ticket, owner: ResumePINOwner) -> Bool {
        guard current(ticket, owner: owner) else { return false }
        pending = nil; active = nil
        return true
    }

    func release(_ ticket: Ticket) {
        if active == ticket { active = nil }
    }

    func profileActivated() {
        since = nil; pending = nil; active = nil
    }

    private func reconcile(owner: ResumePINOwner, requiresPIN: Bool) {
        if !requiresPIN { pending = nil; active = nil }
        else if let old = pending, old.owner != owner {
            pending = Ticket(id: UUID(), owner: owner)
            active = nil
        }
    }
}
