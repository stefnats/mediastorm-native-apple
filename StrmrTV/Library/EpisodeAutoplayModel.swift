import Foundation
import Combine

@MainActor
final class EpisodeAutoplayModel: ObservableObject {
    let context: SourceActionContext
    private let api: any EpisodeAutoplayAPI
    private var closed = false
    private var denied = false
    private var generation = 0
    private var revision = 0
    private var observer: NSObjectProtocol?
    private var task: Task<Void, Never>?
    @Published private(set) var enabled: Bool?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    init(api: any EpisodeAutoplayAPI = APIClient.shared) {
        self.api = api; context = api.sourceContext()
        watch()
    }
    private func watch() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .episodeAutoplayChanged, object: nil, queue: .main) { [weak self] note in
            guard let change = note.object as? EpisodeAutoplayChange else { return }
            MainActor.assumeIsolated { self?.adopt(change) }
        }
    }
    func appear() {
        guard api.isCurrent(context), !denied else { return }
        closed = false; watch()
        if let change = EpisodeAutoplayChanges.latest { adopt(change) }
        load()
    }
    var current: Bool { !closed && !denied && api.isCurrent(context) }
    private func adopt(_ change: EpisodeAutoplayChange) {
        guard current, change.context == context, change.revision > revision else { return }
        revision = change.revision; enabled = change.enabled
    }
    func load() {
        guard current, !busy else { return }
        generation += 1; let owner = generation, before = revision
        enabled = nil; busy = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }; defer { if owner == generation { busy = false; task = nil } }
            do {
                try Task.checkCancellation(); guard current else { return }
                let value = try await api.episodeAutoplay(context)
                try Task.checkCancellation(); guard current, owner == generation else { return }
                if before == revision { enabled = value.enabled }
            } catch { if current && owner == generation && !error.isCancellation { fail(error) } }
        }
    }
    func save(_ value: Bool) {
        guard current, !busy, enabled != nil else { return }
        generation += 1; let owner = generation; busy = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }; defer { if owner == generation { busy = false; task = nil } }
            do {
                try Task.checkCancellation(); guard current else { return }
                let confirmed = try await api.saveEpisodeAutoplay(value, context: context)
                try Task.checkCancellation(); guard current, owner == generation else { return }
                guard confirmed == value else { throw APIError.notReady("The profile choice was not confirmed") }
                enabled = value; EpisodeAutoplayChanges.saved(value, context: context)
            } catch {
                if current && owner == generation && !error.isCancellation { enabled = nil; fail(error) }
            }
        }
    }
    private func fail(_ error: Error) {
        self.error = "The profile choice could not be confirmed. Reload before changing it."
        if [401, 403].contains((error as? APIError)?.statusCode ?? 0) { denied = true; enabled = nil }
    }
    func close() {
        closed = true; generation += 1; task?.cancel(); busy = false
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
    }
}
