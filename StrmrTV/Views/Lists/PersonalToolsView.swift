import SwiftUI

/// These actions live beside the existing Continue Watching, Watchlist,
/// recommendations and custom-list rows, without replacing their navigation.
@MainActor
struct PersonalToolsView: View {
    private enum Tool { case loved, taste, reminders }
    private struct Presentation: Identifiable {
        let id = UUID()
        let tool: Tool
        let context: SourceActionContext
    }
    @State private var presentation: Presentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Personal").font(.headline)
            Button { open(.loved) } label: { Label("Loved titles", systemImage: "heart.fill") }
            Button { open(.taste) } label: { Label("Starting interests", systemImage: "sparkles") }
            if AppSession.shared.profile?.isKidsProfile == false {
                Button { open(.reminders) } label: { Label("Reminders & Inbox", systemImage: "bell") }
            }
        }
        .buttonStyle(.bordered)
        #if os(tvOS)
        .padding(.horizontal, 80)
        #else
        .padding(.horizontal, 16)
        #endif
        .sheet(item: $presentation) { item in
            NavigationStack {
                Group {
                if APIClient.shared.isCurrent(item.context) {
                    switch item.tool {
                    case .loved:
                        let list = BrowseList.remote(id: "loved-stored", name: String(localized: "Loved titles"),
                                                     query: ["source": "loved-stored"])
                        #if os(iOS)
                        MobileListPage(list: list)
                        #else
                        ListPage(list: list)
                        #endif
                    case .taste: TasteSetupView(context: item.context)
                    case .reminders: RemindersNavigationView(context: item.context)
                    }
                } else { Text("Reopen Personal after changing profile or connection.") }
                }
                #if os(iOS)
                .mobileDestinations()
                #else
                .navigationDestination(for: DetailsTarget.self) { DetailsView(target: $0) }
                .navigationDestination(for: PersonRef.self) { PersonPage(person: $0) }
                .navigationDestination(for: BrowseList.self) { ListPage(list: $0) }
                .navigationDestination(for: LibraryShowTarget.self) { LibraryShowView(target: $0) }
                #endif
            }
        }
    }
    private func open(_ tool: Tool) {
        presentation = Presentation(tool: tool, context: APIClient.shared.sourceContext())
    }
}

/// The actual inbox route consumes the no-prewarm destination. Opening a title
/// reads its details; preparing or playing a source remains an explicit action.
@MainActor
private struct RemindersNavigationView: View {
    let context: SourceActionContext
    @State private var destination: ReminderTitleDestination?
    @State private var changed = false
    var body: some View {
        RemindersInboxView(context: context) { value in
            guard value.context == context, APIClient.shared.isCurrent(context), !value.automaticallyPrewarm else {
                changed = true; return
            }
            destination = value
        }
        .navigationDestination(isPresented: Binding(get: { destination != nil }, set: { if !$0 { destination = nil } })) {
            if let destination, APIClient.shared.isCurrent(destination.context) {
                #if os(iOS)
                MobileDetailsView(target: destination.target, automaticallyPrewarm: destination.automaticallyPrewarm)
                #else
                DetailsView(target: destination.target, automaticallyPrewarm: destination.automaticallyPrewarm)
                #endif
            } else { Text("Reopen Personal after changing profile or connection.") }
        }
        .alert("Reopen Personal", isPresented: $changed) { Button("OK", role: .cancel) {} }
            message: { Text("The original profile or connection changed.") }
    }
}
