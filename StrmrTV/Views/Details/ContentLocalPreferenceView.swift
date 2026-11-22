import SwiftUI

/// Shared by the TV and phone details pages. The dedicated source-only endpoint
/// preserves track preferences; an absent capability never enables a fallback write.
struct ContentLocalPreferenceView: View {
    let target: DetailsTarget
    @State private var context: SourceActionContext?
    @State private var preference: ContentLocalPreference?
    @State private var busy = false
    @State private var message: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Button("Inherit profile / server preference") { save(nil) }
                Button("Prefer eligible local files") { save(true) }
                Button("Search first, with local fallback") { save(false) }
            } label: {
                Label(label, systemImage: "externaldrive.badge.checkmark")
            }
            .disabled(busy || preference?.supported != true)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: APIClient.shared.profileID) { await load() }
        .onDisappear { saveTask?.cancel() }
    }

    private var label: String {
        guard let preference else {
            return message == nil ? String(localized: "Loading local source preference…")
                : String(localized: "Local sources: reload required")
        }
        guard preference.supported else { return String(localized: "Local source preference requires an updated server") }
        switch preference.preferLocalFiles {
        case true?: return String(localized: "Local sources: prefer local")
        case false?: return String(localized: "Local sources: search first")
        case nil: return String(localized: "Local sources: inherit")
        }
    }

    private func load() async {
        let original = APIClient.shared.sourceContext()
        context = original
        busy = true
        defer { busy = false }
        do {
            let value = try await APIClient.shared.contentLocalPreference(target.titleID, context: original)
            try Task.checkCancellation()
            guard context == original else { return }
            preference = value
            message = nil
        } catch {
            if !Task.isCancelled { message = String(localized: "The source preference could not be loaded.") }
        }
    }

    private func save(_ value: Bool?) {
        guard !busy, preference?.supported == true, let original = context else { return }
        busy = true
        message = nil
        saveTask = Task {
            defer { busy = false }
            do {
                let saved = try await APIClient.shared.setContentLocalPreference(value, contentID: target.titleID,
                    contentType: target.isMovie ? "movie" : "series", context: original)
                try Task.checkCancellation()
                guard context == original else { return }
                preference = saved
            } catch {
                // A cancelled/lost acknowledgement is not a rollback. Re-read
                // actual state instead of automatically resending the mutation.
                if !Task.isCancelled {
                    preference = nil
                    message = String(localized: "The save could not be confirmed. Reload this page before trying again.")
                }
            }
        }
    }
}
