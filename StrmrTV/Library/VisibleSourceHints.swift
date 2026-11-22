import Combine
import CoreGraphics
import Foundation

enum VisibleSourceCoordinate: Hashable {
    case title(SourceTitleCoordinate)
    case episode(titleID: String, numbering: EpisodeNumbering, value: SourceEpisodeCoordinate)
}
struct VisibleSourceRecord: Equatable {
    let id: UUID
    let coordinate: VisibleSourceCoordinate
    let rect: CGRect
    let order: Int
}
struct VisibleSourceSelection: Equatable {
    var titles: [SourceTitleCoordinate] = []
    var titleID: String?
    var numbering: EpisodeNumbering?
    var episodes: [SourceEpisodeCoordinate] = []
}

/// Consumed geometry selection, independent of lazy creation/pagination. Rects
/// are window-space intersections with all actual enclosing scroll viewports.
enum SourceHintViewport {
    static func visible(_ rect: CGRect, page: CGRect) -> Bool {
        guard !rect.isNull, !page.isNull, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return false }
        let intersection = rect.intersection(page)
        return !intersection.isNull && intersection.width >= min(20,rect.width) && intersection.height >= min(20,rect.height)
    }
    static func select(_ records: [VisibleSourceRecord], page: CGRect, active: Bool) -> VisibleSourceSelection {
        guard active else { return .init() }
        var result = VisibleSourceSelection(), seenTitles = Set<SourceTitleCoordinate>(), seenEpisodes = Set<SourceEpisodeCoordinate>()
        for record in records.sorted(by:{ $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }) where visible(record.rect,page:page) {
            switch record.coordinate {
            case let .title(value):
                if result.titles.count < 24, value.valid, seenTitles.insert(value).inserted { result.titles.append(value) }
            case let .episode(titleID,numbering,value):
                guard !titleID.isEmpty, !numbering.seriesId.isEmpty, value.valid else { continue }
                if result.titleID == nil { result.titleID = titleID; result.numbering = numbering }
                if result.episodes.count < 12, result.titleID == titleID, result.numbering == numbering,
                   seenEpisodes.insert(value).inserted { result.episodes.append(value) }
            }
        }
        return result
    }
}

/// One page owns one original frame/view ID, one serial HTTP worker and the
/// ordered releases. A visibility change never cancels and forgets admitted PUT.
@MainActor
final class VisibleSourceHints: ObservableObject {
    private struct Observed { let value: SourceAvailability? }
    let context: SourceActionContext
    let viewID: String
    private let api: any SourceHintsAPI
    private let wait: (Duration) async throws -> Void
    private let coalesce: Duration
    private var records: [UUID:VisibleSourceRecord] = [:]
    private var page = CGRect.null
    private var active = false
    private var stopped = false
    private var retired = false
    private(set) var selection = VisibleSourceSelection()
    private var generation = 0
    private var version: Int64 = 0
    private var dirty = false
    private var worker: Task<Void,Never>?
    private var waiting: Task<Void,Error>?
    private var lastTitles: [SourceTitleCoordinate]?
    private var lastEpisodes: VisibleSourceSelection?
    private var pendingPolls = 0
    @Published private var titleValues: [SourceTitleCoordinate:Observed] = [:]
    @Published private var episodeValues: [VisibleSourceCoordinate:Observed] = [:]
    @Published private var titlesSupported: Bool?
    @Published private var episodesSupported: Bool?

    init(context: SourceActionContext = APIClient.shared.sourceContext(), api: any SourceHintsAPI = APIClient.shared,
         viewID: String = UUID().uuidString, coalesce: Duration = .milliseconds(250),
         wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for:$0) }) {
        self.context = context; self.api = api; self.viewID = viewID; self.coalesce = coalesce; self.wait = wait
    }
    func current() -> Bool { !stopped && !retired && api.isCurrent(context) }
    func setPage(_ rect: CGRect, visible: Bool) {
        let next = visible ? rect : .null
        guard page != next else { return }; page = next; recompute()
    }
    func setActive(_ value: Bool) {
        guard !stopped, active != value else { return }; active = value; recompute()
    }
    func record(_ value: VisibleSourceRecord) {
        guard !stopped, records[value.id] != value, records[value.id] != nil || records.count < 512 else { return }
        records[value.id] = value; recompute()
    }
    func remove(_ id: UUID) { if records.removeValue(forKey:id) != nil { recompute() } }
    private func recompute() {
        let next = SourceHintViewport.select(Array(records.values),page:page,active:active && current())
        guard next != selection else { return }
        selection = next; generation += 1; pendingPolls = 0; dirty = true; wake()
    }
    private func wake() {
        waiting?.cancel()
        guard worker == nil else { return }
        worker = Task { [self] in
            await run(); worker = nil
            if dirty && !retired { wake() }
        }
    }
    private func delay(_ duration: Duration) async -> Bool {
        let task = Task { [wait] in try await wait(duration) }
        waiting = task
        do { try await task.value; waiting = nil; return true }
        catch { waiting = nil; return false }
    }
    private func nextVersion() throws -> Int64 {
        guard version < Int64.max else { throw SourceHintFailure.changed }
        version += 1; return version
    }
    static func pollDelay(pending: Bool, attempts: inout Int) -> Duration {
        if pending && attempts < 15 { attempts += 1; return .seconds(1) }
        return .seconds(15)
    }
    private func pending(_ values: [SourceAvailability?]) -> Bool {
        values.contains { $0 == nil || ["recheck_queued","not_checked","expired","evidence_not_recorded","prepared_source_requires_recheck"].contains($0?.reason ?? "") }
    }
    private func retire() {
        retired = true; active = false; titleValues = [:]; episodeValues = [:]
        titlesSupported = false; episodesSupported = false
    }
    private func run() async {
        while !retired {
            guard api.isCurrent(context) else { retire(); return }
            if dirty && active && !stopped { if !(await delay(coalesce)) { continue } }
            guard api.isCurrent(context) else { retire(); return }
            let chosen = stopped || !active ? VisibleSourceSelection() : selection
            let expected = generation
            dirty = false
            var hasPending = false, backoff = false
            if titlesSupported != false, !chosen.titles.isEmpty || lastTitles?.isEmpty == false {
                do {
                    let requestVersion = try nextVersion()
                    let request = try SourceHintsWire.titles(context,view:viewID,version:requestVersion,values:chosen.titles)
                    guard api.isCurrent(context) else { retire(); return }
                    lastTitles = chosen.titles
                    let data = try await api.sourceHints(request)
                    guard api.isCurrent(context) else { retire(); return }
                    let value = try SourceHintsWire.titleReply(data,version:requestVersion,requested:chosen.titles)
                    if expected == generation, !stopped {
                        titlesSupported = value.enabled
                        titleValues = Dictionary(uniqueKeysWithValues:value.items.map{($0.coordinate,Observed(value:$0.sourceAvailability))})
                        hasPending = pending(value.items.map(\.sourceAvailability))
                        if !value.enabled { lastTitles = nil }
                    }
                } catch {
                    guard handle(error,titles:true,chosen:chosen,expected:expected) else { return }
                    backoff = true
                }
            }
            if expected != generation { continue }
            if episodesSupported != false, !chosen.episodes.isEmpty || lastEpisodes?.episodes.isEmpty == false {
                do {
                    let requestVersion = try nextVersion()
                    let request = try SourceHintsWire.episodes(context,view:viewID,version:requestVersion,titleID:chosen.titleID,numbering:chosen.numbering,values:chosen.episodes)
                    guard api.isCurrent(context) else { retire(); return }
                    lastEpisodes = chosen
                    let data = try await api.sourceHints(request)
                    guard api.isCurrent(context) else { retire(); return }
                    let value = try SourceHintsWire.episodeReply(data,version:requestVersion,requested:chosen.episodes)
                    if expected == generation, !stopped {
                        episodesSupported = value.enabled
                        if let titleID = chosen.titleID, let numbering = chosen.numbering {
                            episodeValues = Dictionary(uniqueKeysWithValues:value.items.map{(.episode(titleID:titleID,numbering:numbering,value:$0.coordinate),Observed(value:$0.sourceAvailability))})
                        } else { episodeValues = [:] }
                        hasPending = hasPending || pending(value.items.map(\.sourceAvailability))
                        if !value.enabled { lastEpisodes = nil }
                    }
                } catch {
                    guard handle(error,titles:false,chosen:chosen,expected:expected) else { return }
                    backoff = true
                }
            }
            if expected != generation { continue }
            if stopped || !active || chosen.titles.isEmpty && chosen.episodes.isEmpty { return }
            let pause = backoff ? Duration.seconds(15) : Self.pollDelay(pending:hasPending,attempts:&pendingPolls)
            _ = await delay(pause)
        }
    }
    private func handle(_ error: Error, titles: Bool, chosen: VisibleSourceSelection, expected: Int) -> Bool {
        guard api.isCurrent(context) else { retire(); return false }
        let status = (error as? APIError)?.statusCode
        if status == 409 || (error as? SourceHintFailure) == .changed { retire(); return false }
        if [404,405,501].contains(status ?? 0) {
            if titles { titlesSupported = false; lastTitles = nil; titleValues = [:] }
            else { episodesSupported = false; lastEpisodes = nil; episodeValues = [:] }
        } else if expected == generation {
            if titles { for value in chosen.titles { titleValues[value] = Observed(value:nil) } }
            else if let titleID = chosen.titleID, let numbering = chosen.numbering {
                for value in chosen.episodes { episodeValues[.episode(titleID:titleID,numbering:numbering,value:value)] = Observed(value:nil) }
            }
        }
        return true
    }
    func value(_ coordinate: VisibleSourceCoordinate?, annotation: SourceAvailability?) -> SourceAvailability? {
        guard current() else { return nil }
        guard let coordinate else { return annotation }
        switch coordinate {
        case let .title(value):
            guard titlesSupported != false else { return nil }
            if let observed = titleValues[value] { return observed.value }
        case let .episode(titleID,numbering,value):
            guard episodesSupported != false else { return nil }
            let key: VisibleSourceCoordinate
            if titleID.isEmpty, let selectedID = selection.titleID, selection.numbering == numbering {
                key = .episode(titleID:selectedID,numbering:numbering,value:value)
            } else { key = coordinate }
            if let observed = episodeValues[key] { return observed.value }
        }
        return annotation
    }
    func deactivate() { setActive(false) }
    func closeAndDrain() async {
        if !stopped { stopped = true; active = false; selection = .init(); generation += 1; dirty = true; wake() }
        while let task = worker { await task.value }
    }
}

/// Same-profile PIN reentry does not reconstruct the root view. A genuinely
/// visible, unblocked page may therefore acquire a new owner for its NEW frame,
/// after the old admitted work is joined. It never rewrites an old request.
@MainActor
final class SourceHintScopeOwner: ObservableObject {
    @Published private(set) var owner: VisibleSourceHints
    private let api: any SourceHintsAPI
    private let currentContext: () -> SourceActionContext
    private let make: (SourceActionContext) -> VisibleSourceHints
    private var replacement: Task<Void,Never>?
    private var generation = 0
    private var observedContext: SourceActionContext?
    private var rect = CGRect.null
    private var visible = false
    private var allowed = false
    private var closed = false
    init(api: any SourceHintsAPI = APIClient.shared,
         currentContext: @escaping () -> SourceActionContext = { APIClient.shared.sourceContext() },
         make: ((SourceActionContext) -> VisibleSourceHints)? = nil) {
        self.api = api; self.currentContext = currentContext
        let factory = make ?? { VisibleSourceHints(context:$0,api:api) }
        self.make = factory; owner = factory(currentContext())
    }
    func observe(_ rect: CGRect, visible: Bool, allowed: Bool) {
        guard !closed else { return }
        let frame = currentContext()
        if observedContext != frame || self.visible != visible || self.allowed != allowed { generation += 1 }
        observedContext = frame; self.rect = rect; self.visible = visible; self.allowed = allowed
        guard visible && allowed else { owner.deactivate(); owner.setPage(.null,visible:false); return }
        guard api.isCurrent(frame) else { owner.deactivate(); return }
        if owner.context != frame {
            owner.deactivate()
            guard replacement == nil else { return }
            let expected = generation, previous = owner
            replacement = Task { [self] in
                defer { replacement = nil }
                await previous.closeAndDrain()
                guard !closed, expected == generation, self.visible, self.allowed,
                      currentContext() == frame, api.isCurrent(frame) else { return }
                let next = make(frame)
                next.setPage(self.rect,visible:true); next.setActive(true)
                owner = next
            }
            return
        }
        owner.setPage(rect,visible:true); owner.setActive(true)
    }
    func hide() { observe(.null,visible:false,allowed:false) }
    func closeAndDrain() async {
        closed = true; generation += 1; owner.deactivate()
        await replacement?.value; await owner.closeAndDrain()
    }
}
