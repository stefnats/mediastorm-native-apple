import Foundation
import Observation

/// Display data only. Actor/session/PIN authority remains with each original
/// request. Activation clears this profile-local overlay before any new read.
@MainActor @Observable
final class PersonalArtworkStore {
    static let shared = PersonalArtworkStore()
    private var context: SourceActionContext?
    private var values: [String:ContentArtworkPreference] = [:]
    private(set) var revision = 0
    private let api: any ContentArtworkAPI
    @ObservationIgnored private var loadTask: Task<Void,Never>?

    init(api: any ContentArtworkAPI = APIClient.shared) { self.api = api }
    func clear() {
        loadTask?.cancel(); loadTask = nil
        context = nil; values = [:]; revision += 1
    }
    func activate(_ original: SourceActionContext) {
        clear(); context = original
        let expected = revision
        loadTask = Task { [self] in
            do {
                let next = try await api.readAllContentArtwork(original)
                try Task.checkCancellation()
                replaceConfirmedRead(original,readRevision:expected,values:next)
            } catch { /* An optional image read never prevents profile activation. */ }
        }
    }
    func waitForRead() async { await loadTask?.value }
    func replaceConfirmedRead(_ original: SourceActionContext, readRevision: Int, values: [ContentArtworkPreference]) {
        guard context == original, api.isCurrent(original), revision == readRevision else { return }
        var next: [String:ContentArtworkPreference] = [:]
        for value in values {
            guard let id = value.contentId, !id.isEmpty, id == ContentArtworkWire.key(id), next[id] == nil else { return }
            next[id] = value
        }
        self.values = next
    }
    func confirmSaved(_ original: SourceActionContext, titleID: String, value: ContentArtworkPreference, kind: ContentArtworkKind? = nil) {
        guard context?.sameViewer(as:original) == true, api.isCurrent(original),
              value.supported, value.contentId == ContentArtworkWire.key(titleID) else { return }
        let key = ContentArtworkWire.key(titleID)
        if let kind, let previous = values[key] {
            // A one-field ACK cannot revert a newer confirmed opposite field
            // merely because the full response arrived out of order.
            values[key] = ContentArtworkPreference(contentId:key,artworkPreferenceSupported:true,
                posterUrl:kind == .poster ? value.posterUrl : previous.posterUrl,
                backdropUrl:kind == .backdrop ? value.backdropUrl : previous.backdropUrl)
        } else { values[key] = value }
        revision += 1
    }
    func confirmRead(_ original: SourceActionContext, titleID: String, readRevision: Int, value: ContentArtworkPreference) {
        guard revision == readRevision, value.supported,
              value.contentId == nil || value.contentId == ContentArtworkWire.key(titleID),
              value.contentId != nil || value.choice(.poster) == nil && value.choice(.backdrop) == nil else { return }
        let observed = ContentArtworkPreference(contentId:ContentArtworkWire.key(titleID),artworkPreferenceSupported:true,
            posterUrl:value.posterUrl,backdropUrl:value.backdropUrl)
        confirmSaved(original,titleID:titleID,value:observed)
    }
    private func preference(_ id: String) -> ContentArtworkPreference? {
        // A normal refresh may rotate a token. Already confirmed pictures remain
        // local display data for this viewer; every network operation still uses
        // exact original context, and real sign-out/activation explicitly clears.
        guard let context, context.sameViewer(as:api.sourceContext()) else { return nil }
        return values[ContentArtworkWire.key(id)]
    }
    func poster(_ id: String, original: String?) -> String? { preference(id)?.choice(.poster) ?? original }
    func backdrop(_ id: String, original: String?) -> String? { preference(id)?.choice(.backdrop) ?? original }
}

@MainActor @Observable
final class ContentArtworkModel {
    private(set) var title: Title
    let context: SourceActionContext
    private(set) var preference: ContentArtworkPreference?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var confirmation: String?
    private(set) var needsGalleryReload = false
    private let api: any ContentArtworkAPI
    private let store: PersonalArtworkStore
    private var closed = false

    init(title: Title, context: SourceActionContext, api: any ContentArtworkAPI = APIClient.shared,
         store: PersonalArtworkStore = .shared) {
        self.title = title; self.context = context; self.api = api; self.store = store
    }
    func close() { closed = true }
    private func check() throws {
        try Task.checkCancellation()
        guard !closed, api.isCurrent(context) else { throw CancellationError() }
    }
    func load() async {
        guard !busy, !closed, !needsGalleryReload else { return }
        busy = true; message = nil; confirmation = nil; preference = nil
        defer { busy = false }
        do {
            try check()
            let revision = store.revision
            let value = try await api.readContentArtwork(title.id,context:context)
            try check()
            guard value.contentId == nil || value.contentId == ContentArtworkWire.key(title.id) else { throw PersonalTasteError.unavailable }
            guard value.contentId != nil || value.choice(.poster) == nil && value.choice(.backdrop) == nil else { throw PersonalTasteError.unavailable }
            store.confirmRead(context,titleID:title.id,readRevision:revision,value:value)
            preference = value
            if !value.supported { message = String(localized:"Personal pictures are unavailable on this server.") }
        } catch { if !closed, !Task.isCancelled, api.isCurrent(context) { message = PersonalTasteError.message(error) } }
    }
    /// An explicit metadata read renews the server's delivered gallery. Only
    /// after a second confirmed preference read do the new choices become usable.
    /// No previously attempted choice is carried forward or saved automatically.
    func reloadGallery() async {
        guard !busy, !closed, needsGalleryReload else { return }
        busy = true; message = nil; confirmation = nil; preference = nil
        defer { busy = false }
        let original = title
        do {
            try check()
            let delivered = try await api.reloadContentArtworkTitle(original,context:context)
            let fresh = try ContentArtworkWire.confirmGallery(delivered,original:original)
            try check()
            let revision = store.revision
            let value = try await api.readContentArtwork(original.id,context:context)
            try check()
            guard value.supported, value.contentId == nil || value.contentId == ContentArtworkWire.key(original.id),
                  value.contentId != nil || value.choice(.poster) == nil && value.choice(.backdrop) == nil else { throw PersonalTasteError.unavailable }
            store.confirmRead(context,titleID:original.id,readRevision:revision,value:value)
            title = fresh; preference = value; needsGalleryReload = false
            confirmation = String(localized:"Title pictures reloaded. Choose a picture explicitly.")
        } catch {
            if !closed, !Task.isCancelled, api.isCurrent(context) { message = PersonalTasteError.message(error) }
        }
    }
    func save(kind: ContentArtworkKind, url: String?) async {
        guard !busy, !closed, !needsGalleryReload, preference?.supported == true else { return }
        guard ContentArtworkWire.options(title,kind:kind).contains(where:{$0.url == url}) else { return }
        busy = true; message = nil; confirmation = nil
        defer { busy = false }
        do {
            try check()
            let value = try await api.setContentArtwork(title,kind:kind,url:url,context:context)
            try check()
            guard value.supported, value.contentId == ContentArtworkWire.key(title.id), value.choice(kind) == url else { throw PersonalTasteError.unavailable }
            store.confirmSaved(context,titleID:title.id,value:value,kind:kind)
            preference = value
            confirmation = url == nil ? String(localized:"Standard picture restored for this profile.") : String(localized:"Picture saved for this profile.")
        } catch {
            preference = nil // Do not automatically retry an unacknowledged field update.
            if (error as? APIError)?.statusCode == 409 { needsGalleryReload = true }
            if !closed, !Task.isCancelled, api.isCurrent(context) { message = PersonalTasteError.message(error) }
        }
    }
}
