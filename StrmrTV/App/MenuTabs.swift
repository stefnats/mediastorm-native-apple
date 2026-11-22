import SwiftUI
import Combine
import UIKit

/// A tab of the top menu that can be hidden. Home and Settings always show: Home is where
/// the app opens and Settings is where the menu is set.
enum MenuTab: String, CaseIterable, Identifiable, Sendable {
    case live, recordings, sports, watchlist, lists, calendar, search

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .live: "Live"
        case .recordings: "Recordings"
        case .sports: "Sports"
        case .watchlist: "Watchlist"
        case .lists: "Lists"
        case .calendar: "Calendar"
        case .search: "Search"
        }
    }

    /// The Expo app's default `navigationTabVisibility` (home, watchlist, search, lists,
    /// profiles, settings), for servers that send none. Calendar, Recordings and Sports are off unless
    /// the profile's list names them, as in the Expo menu; so is Sports.
    static let serverDefault: Set<String> = ["home", "watchlist", "search", "lists", "profiles", "settings"]
}

/// Which menu tabs show: the profile's `navigationTabVisibility` (set in the Expo app or
/// the admin UI), with this device's own choice per tab on top. A nil choice follows the
/// profile.
@MainActor
final class MenuTabsStore: ObservableObject {
    static let shared = MenuTabsStore()

    private let defaults: UserDefaults

    private enum Keys {
        static let overrides = "menuTabs.overrides"
        /// The profile's list as last loaded, by profile id, so the menu doesn't change
        /// shape once the server answers at launch.
        static let profileTabs = "menuTabs.profileTabs"
        /// This device's tab order (Settings › Menu › Tab Order), by tab id.
        static let order = "menuTabs.order"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Keys.overrides) as? [String: Bool] ?? [:]
        _overrides = Published(initialValue: saved)
        _order = Published(initialValue: defaults.stringArray(forKey: Keys.order) ?? [])
    }

    /// The tabs between Home and Settings in this device's order, by id (a `MenuTab` raw
    /// value or a Home view id); empty for the default order. See `DeviceOrder.apply`.
    @Published private(set) var order: [String] {
        didSet { defaults.set(order, forKey: Keys.order) }
    }

    /// Moves `id` to `target`'s place among `shown`, the tabs as the editor lists them.
    func moveTab(_ id: String, to target: String, in shown: [String]) {
        order = DeviceOrder.move(id, to: target, in: shown)
    }

    /// Saves `shown` as the order (the phone's drag list hands over the whole list).
    func setTabOrder(_ shown: [String]) { order = shown }

    func resetTabOrder() { order = [] }

    @Published private(set) var kidsLiveAvailable = false
    private var kidsLiveContext: SourceActionContext?
    private var kidsAvailabilityGeneration = UUID()
    private var kidsWakeObserver: NSObjectProtocol?
    private var kidsUnlockObserver: AnyCancellable?

    var showsKidsLive: Bool {
        kidsLiveAvailable && kidsLiveContext?.sameViewer(as: APIClient.shared.sourceContext()) == true
    }

    private func watchKidsLiveAvailability() {
        guard kidsWakeObserver == nil else { return }
        kidsWakeObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshKidsLiveAvailability() }
        }
        kidsUnlockObserver = AppSession.shared.$protectedBrowsingBlocked.dropFirst().filter { !$0 }.sink { [weak self] _ in
            Task { @MainActor in await self?.refreshKidsLiveAvailability() }
        }
    }

    private func refreshKidsLiveAvailability() async {
        let generation = UUID()
        kidsAvailabilityGeneration = generation
        let context = APIClient.shared.sourceContext()
        kidsLiveAvailable = false; kidsLiveContext = nil
        guard AppSession.shared.phase == .ready, AppSession.shared.profile?.isKidsProfile == true else { return }
        guard let policy = try? await APIClient.shared.kidsLivePolicy(context: context),
              generation == kidsAvailabilityGeneration, APIClient.shared.isCurrent(context),
              AppSession.shared.profile?.isKidsProfile == true else { return }
        kidsLiveContext = context
        kidsLiveAvailable = policy.configured
    }

    /// The profile's visible tabs, as last loaded.
    @Published private(set) var profileTabs: Set<String> = MenuTab.serverDefault

    /// This device's choices, by tab.
    @Published private(set) var overrides: [String: Bool] {
        didSet { defaults.set(overrides, forKey: Keys.overrides) }
    }

    func profileShows(_ tab: MenuTab) -> Bool { profileTabs.contains(tab.rawValue) }

    func isVisible(_ tab: MenuTab) -> Bool { overrides[tab.rawValue] ?? profileShows(tab) }

    func binding(for tab: MenuTab) -> Binding<Bool?> {
        Binding(get: { self.overrides[tab.rawValue] }, set: { self.overrides[tab.rawValue] = $0 })
    }

    /// Movies, Shows or a custom Home page as a menu item of its own: off unless the
    /// profile's list names it (as in the Expo menu) or this device turns it on.
    func profileShows(homeView id: String) -> Bool { profileTabs.contains(id) }

    func isVisible(homeView id: String) -> Bool { overrides[id] ?? profileShows(homeView: id) }

    func binding(forHomeView id: String) -> Binding<Bool?> {
        Binding(get: { self.overrides[id] }, set: { self.overrides[id] = $0 })
    }

    func resetOverrides() { overrides = [:] }

    /// Shows the profile's last loaded list, then asks the server for its current one.
    func refresh(profileID: String) async {
        watchKidsLiveAvailability()
        await refreshKidsLiveAvailability()
        var cached = defaults.dictionary(forKey: Keys.profileTabs) as? [String: [String]] ?? [:]
        let initial = cached[profileID].map(Set.init) ?? MenuTab.serverDefault
        if initial != profileTabs { profileTabs = initial }
        guard let tabs = await APIClient.shared.navigationTabVisibility() else { return }
        let loaded = Set(tabs)
        if loaded != profileTabs { profileTabs = loaded }
        cached[profileID] = tabs
        defaults.set(cached, forKey: Keys.profileTabs)
    }
}
