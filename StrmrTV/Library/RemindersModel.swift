import Combine
import Foundation

/// A page/dialog owns the original viewer and every admitted request. A failed
/// write is not a rollback; only an explicit subsequent read enables more changes.
@MainActor
final class RemindersModel: ObservableObject {
    enum Recovery: Equatable { case refresh, reloadTitle, manage }
    let context: SourceActionContext
    @Published private(set) var subject: ReminderSubject?
    @Published private(set) var reminders: [Reminder] = []
    @Published private(set) var events: [ReminderEvent] = []
    @Published private(set) var supported = false
    @Published private(set) var busy = false
    @Published private(set) var closed = false
    @Published private(set) var unreadOnly = false
    @Published private(set) var nextCursor: String?
    @Published private(set) var message: String?
    @Published private(set) var recovery = Recovery.refresh
    private let api: any ReminderAPI
    private var work: Task<Void, Never>?
    private var cursors = Set<String>()
    private var withInbox = true

    init(context: SourceActionContext, subject: ReminderSubject? = nil, api: any ReminderAPI = APIClient.shared) {
        self.context = context; self.subject = subject; self.api = api
    }
    func requireCurrent() throws {
        try Task.checkCancellation()
        guard !closed, api.isCurrent(context), api.remindersAllowed(context) else { throw ReminderFailure.changed }
    }
    func close() {
        closed = true; supported = false; work?.cancel()
        reminders = []; events = []; nextCursor = nil
    }
    func appear(withInbox: Bool = true) async {
        if closed {
            let previous = work
            await previous?.value
            guard !Task.isCancelled, api.isCurrent(context), api.remindersAllowed(context) else { return }
            closed = false
        }
        guard !Task.isCancelled else { return }
        load(withInbox: withInbox)
    }
    private func support(_ value: Bool?, monitoring: String?) throws {
        guard value == true, monitoring == "observations_only" else { throw ReminderFailure.unsupported }
    }
    private func validate(_ values: [Reminder]) throws -> [Reminder] {
        guard values.count <= 2000, values.allSatisfy(ReminderChoices.valid) else { throw ReminderFailure.invalid }
        var ids = Set<String>(); return values.filter { ids.insert($0.id).inserted }
    }
    private func validate(_ values: [ReminderEvent]) throws -> [ReminderEvent] {
        guard values.count <= 100, values.allSatisfy(ReminderChoices.valid) else { throw ReminderFailure.invalid }
        var ids = Set<String>()
        return values.filter { $0.dismissedAt == nil && (!unreadOnly || $0.readAt == nil) && ids.insert($0.id).inserted }
    }
    private func cursor(_ value: String?) throws -> String? {
        if let value {
            guard !value.isEmpty, value.count <= 2048, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), !cursors.contains(value) else { throw ReminderFailure.invalid }
        }
        return value
    }
    private func begin(failureRecovery: Recovery = .refresh, _ action: @escaping () async throws -> Void) {
        guard !busy, !closed else { return }
        do { try requireCurrent() } catch { close(); return }
        busy = true; message = nil
        work = Task { [self] in
            defer { busy = false; work = nil }
            do { try requireCurrent(); try await action(); try requireCurrent() }
            catch is CancellationError {
                if !closed {
                    supported = false; nextCursor = nil; recovery = failureRecovery
                    message = String(localized: "The operation was cancelled. Refresh before trying again; its outcome is not assumed.")
                }
            }
            catch {
                guard !closed, api.isCurrent(context), api.remindersAllowed(context) else { close(); return }
                supported = false; nextCursor = nil
                switch (error as? APIError)?.code {
                case "reminder_metadata_reload_required":
                    recovery = .reloadTitle; message = String(localized: "Reload this title's metadata, then choose the reminder again.")
                case "reminder_interest_limit":
                    recovery = .manage; message = String(localized: "Stop active reminders or dismiss old inbox updates before adding another.")
                default:
                    recovery = failureRecovery
                    if let error = error as? ReminderFailure { message = error.localizedDescription }
                    else if [404, 405, 501].contains((error as? APIError)?.statusCode ?? 0) { message = ReminderFailure.unsupported.localizedDescription }
                    else { message = String(localized: "The outcome could not be confirmed. Refresh before trying again; no change is resent automatically.") }
                }
            }
        }
    }
    func load(withInbox: Bool = true) {
        guard !busy else { return }
        self.withInbox = withInbox
        begin { [self] in
            supported = false
            let list = try await api.reminders(context)
            try requireCurrent(); try support(list.remindersSupported, monitoring: list.monitoring)
            let subscriptions = try validate(list.items)
            let inbox = withInbox ? try await api.reminderInbox(context, unread: unreadOnly, cursor: nil) : nil
            try requireCurrent()
            cursors.removeAll()
            let rows: [ReminderEvent]
            let next: String?
            if let inbox {
                try support(inbox.remindersSupported, monitoring: inbox.monitoring)
                rows = try validate(inbox.items); next = try cursor(inbox.nextCursor)
            } else { rows = []; next = nil }
            try requireCurrent()
            reminders = subscriptions; events = rows; nextCursor = next
            supported = true; recovery = .refresh
        }
    }
    func setUnread(_ value: Bool) {
        guard !busy, !closed, value != unreadOnly else { return }
        unreadOnly = value; events = []; nextCursor = nil; load()
    }
    func more() {
        guard supported, !busy, let requested = nextCursor else { return }
        begin { [self] in
            let value = try await api.reminderInbox(context, unread: unreadOnly, cursor: requested)
            try requireCurrent(); try support(value.remindersSupported, monitoring: value.monitoring)
            let rows = try validate(value.items)
            cursors.insert(requested)
            let next = try cursor(value.nextCursor)
            var ids = Set(events.map(\.id))
            events += rows.filter { ids.insert($0.id).inserted }; nextCursor = next
        }
    }
    func create(_ choice: ReminderChoice) {
        guard supported, let subject, subject.choices.contains(choice) else { return }
        begin { [self] in
            let result = try await api.createReminder(choice, context: context)
            try requireCurrent(); try support(result.remindersSupported, monitoring: result.monitoring)
            guard let item = result.item, choice.confirms(item, requested: result.requestedContentId, subject: subject) else { throw ReminderFailure.invalid }
            reminders.removeAll { $0.id == item.id }; reminders.append(item)
            message = String(localized: "Reminder saved. Updates depend on normal observations in the app.")
        }
    }
    func revoke(_ value: Reminder) {
        guard supported, reminders.contains(value) else { return }
        begin { [self] in
            try await api.revokeReminder(value.id, context: context)
            try requireCurrent()
            reminders.removeAll { $0.id == value.id }
            // Existing inbox events remain independently manageable.
        }
    }
    func update(_ value: ReminderEvent, read: Bool? = nil, dismissed: Bool? = nil) {
        guard supported, events.contains(value), read != nil || dismissed != nil else { return }
        begin { [self] in
            let reply = try await api.markReminderEvent(value.id, read: read, dismissed: dismissed, context: context)
            try requireCurrent()
            guard reply.remindersSupported == true, let saved = reply.item, ReminderChoices.valid(saved), saved.id == value.id,
                  saved.reminderId == value.reminderId, saved.contentId == value.contentId, saved.contentType == value.contentType,
                  saved.eventKind == value.eventKind, saved.episode == value.episode, saved.releaseType == value.releaseType,
                  read.map({ (saved.readAt != nil) == $0 }) ?? true,
                  dismissed.map({ (saved.dismissedAt != nil) == $0 }) ?? true else { throw ReminderFailure.invalid }
            events = events.map { $0.id == saved.id ? saved : $0 }.filter { $0.dismissedAt == nil && (!unreadOnly || $0.readAt == nil) }
        }
    }
    func reloadTitle() {
        guard recovery == .reloadTitle, let original = subject else { return }
        begin(failureRecovery: .reloadTitle) { [self] in
            let loaded = try await api.reloadReminderTitle(original, context: context)
            try requireCurrent()
            guard loaded.target == original.target else { throw ReminderFailure.invalid }
            let list = try await api.reminders(context)
            try requireCurrent(); try support(list.remindersSupported, monitoring: list.monitoring)
            let subscriptions = try validate(list.items)
            subject = loaded; reminders = subscriptions; supported = true; recovery = .refresh
            message = String(localized: "Title metadata reloaded. Choose a reminder explicitly.")
        }
    }
    func open(_ value: ReminderEvent) -> ReminderTitleDestination? {
        guard supported, !busy, events.contains(value), (try? requireCurrent()) != nil,
              let target = ReminderChoices.details(value.contentId, kind: value.contentType, title: value.title) else { return nil }
        return ReminderTitleDestination(target: target, context: context)
    }
    func open(_ value: Reminder) -> ReminderTitleDestination? {
        guard supported, !busy, reminders.contains(value), (try? requireCurrent()) != nil,
              let target = ReminderChoices.details(value.contentId, kind: value.contentType, title: value.title) else { return nil }
        return ReminderTitleDestination(target: target, context: context)
    }
    func refresh() { load(withInbox: withInbox) }
}
