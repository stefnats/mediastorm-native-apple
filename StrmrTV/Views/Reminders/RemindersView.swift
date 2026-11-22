import SwiftUI
import UIKit

/// Self-contained entry works inside both existing More menus. UIKit owns the
/// sheet after its menu cell disappears; no global detail-page state is changed.
struct ReminderEntryButton: View {
    let target: DetailsTarget
    let title: Title?
    let seasons: [Season]
    var body: some View {
        if AppSession.shared.profile?.isKidsProfile == false, let title,
           let subject = try? ReminderSubject(target: target, title: title, seasons: seasons) {
            Button {
                ReminderPresentation.show(subject, context: APIClient.shared.sourceContext())
            } label: { Label("Remind Me…", systemImage: "bell.badge") }
            .accessibilityIdentifier("reminders.title-entry")
        }
    }
}

@MainActor
enum ReminderPresentation {
    static func show(_ subject: ReminderSubject, context: SourceActionContext) {
        guard APIClient.shared.remindersAllowed(context) else { return }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top, !(top is EnginePlayerViewController), !(top is UIAlertController) else { return }
        let controller = UIHostingController(rootView: ReminderDialog(subject: subject, context: context))
        #if os(iOS)
        controller.modalPresentationStyle = .formSheet
        #else
        controller.modalPresentationStyle = .overFullScreen
        #endif
        top.present(controller, animated: true)
    }
}

private struct ReminderDialog: View {
    @StateObject private var model: RemindersModel
    @Environment(\.dismiss) private var dismiss
    init(subject: ReminderSubject, context: SourceActionContext) {
        _model = StateObject(wrappedValue: RemindersModel(context: context, subject: subject))
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.subject?.title.name ?? String(localized: "Reminder")).font(.headline)
                    Text(ReminderText.passive).font(.caption).foregroundStyle(.secondary)
                }
                if model.supported, let subject = model.subject {
                    Section("Choose a reminder") {
                        ForEach(subject.choices) { choice in
                            Button(choice.label) { model.create(choice) }
                                .disabled(model.busy)
                                .accessibilityIdentifier("reminders.choose.\(choice.id)")
                        }
                    }
                }
                ReminderStatus(model: model)
                if model.recovery == .manage {
                    NavigationLink("Manage reminders and inbox") {
                        RemindersInboxView(context: model.context)
                    }
                    .disabled(model.busy)
                }
                Section {
                    Button("Close") { dismiss() }
                }
            }
            .navigationTitle("Remind Me")
        }
        .task { await model.appear(withInbox: false) }
        .onDisappear { model.close() }
    }
}

/// Root's personal hub supplies the actual detail router. With no router this
/// view still manages subscriptions/events and never opens a prewarming page.
struct RemindersInboxView: View {
    @StateObject private var model: RemindersModel
    private let onOpen: ((ReminderTitleDestination) -> Void)?
    init(context: SourceActionContext? = nil, onOpen: ((ReminderTitleDestination) -> Void)? = nil) {
        _model = StateObject(wrappedValue: RemindersModel(context: context ?? APIClient.shared.sourceContext()))
        self.onOpen = onOpen
    }
    var body: some View {
        List {
            Section {
                Text(ReminderText.passive).font(.caption).foregroundStyle(.secondary)
                Button(model.unreadOnly ? "Show all inbox updates" : "Show unread updates only") { model.setUnread(!model.unreadOnly) }
                    .disabled(model.busy || model.closed)
            }
            Section("Active reminders") {
                if model.reminders.isEmpty, model.supported { Text("No active reminders") }
                ForEach(model.reminders) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title.name).font(.headline)
                        Text(item.description).font(.caption)
                        if let label = item.deviceLabel { Text(label).font(.caption).foregroundStyle(.secondary) }
                        if let date = ReminderText.recorded(item.createdAt) { Text(date).font(.caption).foregroundStyle(.secondary) }
                        if let onOpen {
                            Button("Open title") { if let target = model.open(item) { onOpen(target) } }
                                .disabled(model.busy || !model.supported)
                        }
                        Button("Stop reminder", role: .destructive) { model.revoke(item) }
                            .disabled(model.busy || !model.supported)
                            .accessibilityIdentifier("reminders.revoke.\(item.id)")
                    }
                }
            }
            Section("Inbox") {
                if model.events.isEmpty, model.supported { Text("No inbox updates") }
                ForEach(model.events) { event in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.title.name).font(.headline)
                        Text(event.description).font(.caption)
                        if let date = ReminderText.recorded(event.occurredAt) { Text(date).font(.caption).foregroundStyle(.secondary) }
                        Text(event.readAt == nil ? "Unread" : "Read").font(.caption)
                        if let onOpen {
                            Button("Open title") { if let target = model.open(event) { onOpen(target) } }
                                .disabled(model.busy || !model.supported)
                                .accessibilityIdentifier("reminders.open.\(event.id)")
                        }
                        Button(event.readAt == nil ? "Mark as read" : "Mark as unread") { model.update(event, read: event.readAt == nil) }
                            .disabled(model.busy || !model.supported)
                        Button("Dismiss update", role: .destructive) { model.update(event, dismissed: true) }
                            .disabled(model.busy || !model.supported)
                    }
                }
                if model.nextCursor != nil {
                    Button("Load more updates") { model.more() }.disabled(model.busy || !model.supported)
                        .accessibilityIdentifier("reminders.more")
                }
            }
            ReminderStatus(model: model)
        }
        .navigationTitle("Reminders & Inbox")
        .task { await model.appear() }
        .onDisappear { model.close() }
    }
}

private struct ReminderStatus: View {
    @ObservedObject var model: RemindersModel
    var body: some View {
        Section {
            if model.busy { ProgressView() }
            if model.closed { Text("Reopen reminders under the current adult profile.").foregroundStyle(.secondary) }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !model.closed {
                if model.recovery == .reloadTitle, model.subject != nil {
                    Button("Reload title metadata") { model.reloadTitle() }.disabled(model.busy)
                        .accessibilityIdentifier("reminders.reload-title")
                }
                Button("Refresh reminders") { model.refresh() }.disabled(model.busy)
                    .accessibilityIdentifier("reminders.refresh")
            }
        }
    }
}
