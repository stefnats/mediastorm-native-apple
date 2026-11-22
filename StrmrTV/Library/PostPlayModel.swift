import Combine
import Foundation

@MainActor
final class PostPlayModel: ObservableObject {
    let offer: PostPlayOffer
    private let api: any PostPlayAPI
    private var closed = false
    private var denied = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var questionDismissed = false
    private var questionOffered = false
    private var listTasks: [UUID: Task<Void, Never>] = [:]
    private var navigationOwner: UUID?
    @Published private(set) var title: Title?
    @Published private(set) var rating: PersonalTitleRating?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var suggestionsError: String?
    @Published private(set) var suggestions: [PostPlaySuggestion] = []
    @Published private(set) var suggestionsSource: String?
    @Published private(set) var suggestionsLoading = false
    @Published private(set) var question = false
    @Published var expanded = false
    @Published private(set) var saved = Set<String>()
    @Published private(set) var uncertainSaves = Set<String>()
    @Published private(set) var listSaving = Set<String>()
    @Published private(set) var listError: String?
    init(offer: PostPlayOffer, api: any PostPlayAPI = APIClient.shared) { self.offer = offer; self.api = api }
    var current: Bool { !closed && !denied && api.isCurrent(offer.context) }
    var heading: String {
        if offer.request.title.isMovie { return "Movie finished" }
        let stamp = offer.request.postPlayStamp
        let lifecycle = title?.lifecycleStatus ?? stamp?.lifecycle
        let ended = stamp?.orderingKnown == true && stamp?.upcoming == nil && ["ended", "canceled", "cancelled"].contains(lifecycle?.lowercased() ?? "")
        return ended ? "Series finished" : "Episode finished"
    }
    func close() { navigationOwner = nil; closed = true; generation += 1; task?.cancel(); listTasks.values.forEach { $0.cancel() }; suggestions = []; loading = false; saving = false; suggestionsLoading = false; listSaving = [] }
    private func check(_ owner: Int) throws {
        try Task.checkCancellation(); guard current, owner == generation else { throw CancellationError() }
    }
    func load() {
        guard current, !loading, !saving, listSaving.isEmpty else { return }
        guard offer.completion != nil else { error = offer.failure ?? PostPlayFailure.completion.localizedDescription; return }
        generation += 1; let owner = generation
        task?.cancel(); loading = true; error = nil; rating = nil; question = false; suggestions = []; suggestionsSource = nil; navigationOwner = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if owner == generation { loading = false; task = nil } }
            do {
                try check(owner)
                let value = try await api.postPlayContext(offer)
                try check(owner); try value.validate(offer.request.title)
                title = value.title; rating = value.rating
                question = value.rating == .none && !questionDismissed && !questionOffered
                if question { questionOffered = true }
                await refreshSuggestions(owner)
            } catch { if current && owner == generation && !error.isCancellation { self.error = PersonalTasteError.message(error); retireDenial(error) } }
        }
    }
    func skip() { guard current, !saving else { return }; questionDismissed = true; question = false; expanded = false }
    func edit() { guard current, rating != nil, !saving else { return }; question = true; expanded = true }
    func rate(_ value: PersonalTitleRating) {
        guard current, !loading, !saving, listSaving.isEmpty, rating != nil, let title else { return }
        if rating == value { questionDismissed = true; question = false; return }
        generation += 1; let owner = generation
        task?.cancel(); saving = true; error = nil; suggestions = []; suggestionsSource = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if owner == generation { saving = false; task = nil } }
            do {
                try check(owner)
                let confirmed = try await api.setRating(value, target: DetailsTarget(title), context: offer.context)
                try check(owner); guard confirmed == value else { throw PostPlayFailure.invalid }
                rating = confirmed; questionDismissed = true; question = false; expanded = false
                PersonalTasteChanges.saved(offer.context)
                await refreshSuggestions(owner)
            } catch {
                if current && owner == generation && !error.isCancellation {
                    // A lost acknowledgement may have saved Dislike. Do not put
                    // old positive suggestions or an optimistic rating back.
                    rating = nil; suggestions = []; suggestionsSource = nil
                    self.error = PersonalTasteError.message(error); retireDenial(error)
                }
            }
        }
    }
    private func refreshSuggestions(_ owner: Int) async {
        guard let expected = rating else { return }
        suggestionsLoading = true; suggestionsError = nil
        defer { if owner == generation { suggestionsLoading = false } }
        do {
            try check(owner)
            let result = try await api.postPlaySuggestions(offer)
            try check(owner); try result.validate(target: offer.request.title, rating: expected)
            suggestions = result.items.map { PostPlaySuggestion($0.title) }; suggestionsSource = result.source
        } catch {
            if current && owner == generation && !error.isCancellation {
                suggestions = []; suggestionsSource = nil; suggestionsError = PostPlayFailure.unavailable.localizedDescription; retireDenial(error)
            }
        }
    }
    private func contains(_ row: PostPlaySuggestion) -> Bool { current && !loading && !saving && suggestions.contains { $0 === row } }
    func details(_ row: PostPlaySuggestion) -> DetailsTarget? {
        guard contains(row), navigationOwner == nil else { return nil }; return DetailsTarget(row.title)
    }
    func reminder() -> ReminderSubject? {
        guard current, let title, ReleaseBadge.forEpisode(airDate: offer.request.postPlayStamp?.upcoming?.airedDate) != nil else { return nil }
        return try? ReminderSubject(target: DetailsTarget(title), title: title, seasons: offer.request.postPlayStamp?.seasons ?? [])
    }
    func save(_ row: PostPlaySuggestion) {
        guard contains(row), !listSaving.contains(row.id), !saved.contains(row.id) else { return }
        let owner = generation; listSaving.insert(row.id); listError = nil
        let checkOnly = uncertainSaves.contains(row.id)
        let id = UUID()
        listTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { listTasks[id] = nil; if current && owner == generation { listSaving.remove(row.id) } }
            do {
                try check(owner); guard contains(row) else { return }
                if checkOnly {
                    let exists = try await api.postPlayContains(row.title, context: offer.context)
                    try check(owner); guard contains(row) else { return }
                    uncertainSaves.remove(row.id)
                    if exists { saved.insert(row.id) }
                    else { listError = "This title was not confirmed in My List. Choose Save again if wanted." }
                    return
                }
                try await api.postPlaySave(row.title, context: offer.context)
                try check(owner); guard contains(row) else { return }
                saved.insert(row.id)
                NotificationCenter.default.post(name: .titleStateChanged, object: nil)
            } catch {
                if current && owner == generation && !error.isCancellation {
                    uncertainSaves.insert(row.id); listError = "The save acknowledgement is unknown. Check its status before saving again."
                    retireDenial(error)
                }
            }
        }
    }
    func preparePlay(_ row: PostPlaySuggestion) async throws -> PlaybackRequest {
        guard contains(row), navigationOwner == nil else { throw CancellationError() }
        let owner = generation, navigation = UUID()
        navigationOwner = navigation
        // A refreshed generation rejects the old result, but its actual lookup
        // still releases its own admission. It cannot clear a replacement's.
        defer { if navigationOwner == navigation { navigationOwner = nil } }
        let bundle = try await api.postPlayDetails(row.title, context: offer.context)
        try check(owner); guard contains(row) else { throw CancellationError() }
        let title: Title
        let episode: Episode?
        let seasons: [Season]
        if row.title.isMovie {
            guard let movie = bundle.movieDetails, PersonalTasteWire.same(movie, row.title) else { throw PostPlayFailure.invalid }
            title = movie; episode = nil; seasons = []
        } else {
            guard let details = bundle.seriesDetails, PersonalTasteWire.same(details.title, row.title), let next = bundle.upNextEpisode,
                  let actual = details.seasons.flatMap(\.episodes).first(where: { DetailsView.isUpNext($0, next) }),
                  ReleaseBadge.forEpisode(airDate: actual.airedDate) == nil else {
                throw APIError.notReady("Choose an available episode in Details before playing this series.")
            }
            title = details.title; episode = actual; seasons = details.seasons
        }
        return DetailsRequest.make(target: DetailsTarget(title), title: title, seasons: seasons, episode: episode,
            start: bundle.resume?.startPoint, seed: UInt64.random(in: 0...UInt64.max), library: nil)
    }
    private func retireDenial(_ error: Error) {
        guard [401, 403].contains((error as? APIError)?.statusCode ?? 0) else { return }
        denied = true; suggestions = []; question = false; rating = nil; task?.cancel(); listTasks.values.forEach { $0.cancel() }
    }
    func playbackFailed(_ error: Error) { if current && !error.isCancellation { self.error = error.localizedDescription; retireDenial(error) } }
}
