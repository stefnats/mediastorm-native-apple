import SwiftUI

@MainActor
final class KidsLiveStore: ObservableObject {
    @Published private(set) var channels: [KidsLiveChannel] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    private(set) var context: SourceActionContext
    private let api: any KidsLiveAPI
    private var loadingNow = false

    init(context: SourceActionContext = APIClient.shared.sourceContext(), api: any KidsLiveAPI = APIClient.shared) {
        self.context = context; self.api = api
    }
    func load() async {
        guard !loadingNow else { return }
        context = api.sourceContext()
        loadingNow = true; loading = true; channels = []; message = nil
        defer { loadingNow = false; loading = false }
        do {
            guard api.isCurrent(context) else { throw CancellationError() }
            let policy = try await api.kidsLivePolicy(context: context)
            guard api.isCurrent(context), !Task.isCancelled else { return }
            guard policy.configured else { throw APIError.notReady("A parent can enable programme-limited Live TV in the server's Kids Settings.") }
            let rows = try await api.kidsLiveChannels(context: context)
            guard api.isCurrent(context), !Task.isCancelled else { return }
            channels = rows
        } catch {
            if api.isCurrent(context), !Task.isCancelled { message = error.localizedDescription }
        }
    }
}
