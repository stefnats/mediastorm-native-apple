import Foundation
import XCTest
@testable import StrmrTV

@MainActor
enum ReminderFixture {
    static func context(_ profile: String = "original", proof: String = "synthetic-original") -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://synthetic.invalid/proxy")!, profileID: profile,
            clientID: "client", sessionToken: "synthetic-token", unlock: proof)
    }
    static func decode<T: Decodable>(_ value: [String: Any], as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    static func title(series: Bool = false) -> [String: Any] {
        ["id": series ? "tmdb:series:41" : "tmdb:movie:123", "name": "Synthetic Reminder", "mediaType": series ? "series" : "movie", "tmdbId": series ? 41 : 123]
    }
    static func episode(order: String = "official", owner: String = "tvdb:series:74852") -> [String: Any] {
        ["id": "episode-3", "name": "Synthetic Episode", "seasonNumber": 2, "episodeNumber": 3, "numbering": ["seriesId": owner, "ordering": order]]
    }
    static func subject(series: Bool = false, order: String = "official", owner: String = "tvdb:series:74852") throws -> ReminderSubject {
        let title: Title = try decode(title(series: series))
        let ep: Episode = try decode(episode(order: order, owner: owner))
        let season = Season(id: "season-2", name: "Season 2", number: 2, episodes: [ep])
        return try ReminderSubject(target: DetailsTarget(title), title: title, seasons: series ? [season] : [])
    }
    static func reminder(_ choice: ReminderChoice? = nil, id: String = "reminder-one", currentDevice: Bool = true) throws -> [String: Any] {
        let value = try choice ?? subject().choices[0]
        var raw = try value.body()
        raw["id"] = id; raw["title"] = title(series: value.contentType == "series")
        raw["state"] = "waiting"; raw["createdAt"] = "2026-11-22T12:00:00Z"; raw["createdOnCurrentDevice"] = currentDevice
        return raw
    }
    static func event(id: String = "event-one", read: Bool = false, dismissed: Bool = false) -> [String: Any] {
        var raw: [String: Any] = ["id": id, "reminderId": "reminder-one", "contentId": "tmdb:movie:123", "contentType": "movie",
            "eventKind": "release", "title": title(), "releaseType": "digital", "occurredAt": "2026-11-22T12:00:00Z", "candidateOnly": false]
        if read { raw["readAt"] = "2026-11-22T12:01:00Z" }; if dismissed { raw["dismissedAt"] = "2026-11-22T12:02:00Z" }
        return raw
    }
    static func list(items: [[String: Any]]? = nil, support: Bool = true) throws -> ReminderList {
        try decode(["remindersSupported": support, "monitoring": "observations_only", "items": try items ?? [reminder()]])
    }
    static func inbox(items: [[String: Any]]? = nil, cursor: String? = nil) throws -> ReminderInbox {
        var raw: [String: Any] = ["remindersSupported": true, "monitoring": "observations_only", "items": items ?? [event()]]
        if let cursor { raw["nextCursor"] = cursor }; return try decode(raw)
    }
    static func error(_ code: String, status: Int = 409) -> APIError {
        .http(HTTPFailure(status: status, data: Data("{\"code\":\"\(code)\",\"error\":\"Synthetic fixture\"}".utf8)))
    }
}

@MainActor
final class ReminderContractTests: XCTestCase {
    func testActualGoMovieChoicesHaveExactSeparateReleaseAndSourceBodies() throws {
        let subject = try ReminderFixture.subject()
        XCTAssertEqual(subject.choices.count, 4)
        XCTAssertEqual(subject.choices.compactMap(\.releaseType), ["digital", "physical", "theatrical"])
        for choice in subject.choices {
            let body = try choice.body()
            XCTAssertEqual(body["contentId"] as? String, "tmdb:movie:123")
            XCTAssertEqual(body["contentType"] as? String, "movie")
            XCTAssertNil(body["episode"]); XCTAssertNil(body["profileId"])
        }
    }
    func testOfficialEpisodeUsesDeliveredNumberingEvenAcrossMetadataProviders() throws {
        let subject = try ReminderFixture.subject(series: true)
        XCTAssertEqual(subject.choices.count, 2)
        XCTAssertEqual(subject.choices.first?.eventKind, "new_episode")
        let choice = try XCTUnwrap(subject.choices.last), ep = try XCTUnwrap(choice.episode)
        XCTAssertEqual(ep.numbering.seriesId, "tvdb:series:74852")
        let body = try choice.body(), episode = try XCTUnwrap(body["episode"] as? [String: Any])
        XCTAssertEqual(episode["episodeId"] as? String, "episode-3")
        XCTAssertEqual(episode["seasonNumber"] as? Int, 2)
        XCTAssertEqual((episode["numbering"] as? [String: Any])?["ordering"] as? String, "official")
        XCTAssertEqual(body["contentId"] as? String, "tmdb:series:41")
    }
    func testUnknownAlternateAndUnanchoredEpisodeNumberingNeverBecomeSourceChoices() throws {
        for (order, owner) in [("dvd", "tvdb:series:74852"), ("official", "unknown"), ("absolute", "tmdb:series:41")] {
            XCTAssertEqual(try ReminderFixture.subject(series: true, order: order, owner: owner).choices.count, 1)
        }
        let episode = ReminderEpisode(episodeId: "ep", numbering: EpisodeNumbering(seriesId: "tvdb:series:74852", ordering: "dvd"), seasonNumber: 2, episodeNumber: 3)
        XCTAssertThrowsError(try ReminderChoice(contentId: "tmdb:series:41", contentType: "series", eventKind: "matching_source", releaseType: nil, episode: episode).body())
    }
    func testContradictoryDeliveredEpisodeIdentityNeverProducesAChoice() throws {
        let original = try ReminderFixture.subject(series: true)
        var raw = ReminderFixture.episode(); raw["episodeNumber"] = 4
        let conflict: Episode = try ReminderFixture.decode(raw)
        let subject = try ReminderSubject(target: original.target, title: original.title,
            seasons: [Season(id: "season", name: "Season", number: 2, episodes: original.seasons[0].episodes + [conflict])])
        XCTAssertEqual(subject.choices.map(\.eventKind), ["new_episode"])
    }
    func testSeriesSubscriptionAndObservedEventHaveDifferentEpisodeRequirements() throws {
        let subject = try ReminderFixture.subject(series: true)
        let subscription: Reminder = try ReminderFixture.decode(ReminderFixture.reminder(subject.choices[0]))
        XCTAssertTrue(ReminderChoices.valid(subscription)); XCTAssertNil(subscription.episode)
        var raw = ReminderFixture.event()
        raw["contentId"] = subject.title.id; raw["contentType"] = "series"; raw["title"] = ReminderFixture.title(series: true)
        raw["eventKind"] = "new_episode"; raw["releaseType"] = nil
        XCTAssertFalse(ReminderChoices.valid(try ReminderFixture.decode(raw, as: ReminderEvent.self)))
        var episode = ReminderFixture.episode(); episode["episodeId"] = episode.removeValue(forKey: "id"); episode["name"] = nil
        raw["episode"] = episode
        XCTAssertTrue(ReminderChoices.valid(try ReminderFixture.decode(raw, as: ReminderEvent.self)))
    }
    func testActualGoSubscriptionEventAndDeviceLabelsRemainIndependent() throws {
        let subscription: Reminder = try ReminderFixture.decode(ReminderFixture.reminder())
        let event: ReminderEvent = try ReminderFixture.decode(ReminderFixture.event())
        XCTAssertTrue(ReminderChoices.valid(subscription)); XCTAssertTrue(ReminderChoices.valid(event))
        XCTAssertNil(subscription.deviceLabel)
        let source = try ReminderFixture.subject().choices.last!
        let other: Reminder = try ReminderFixture.decode(ReminderFixture.reminder(source, currentDevice: false))
        XCTAssertEqual(other.deviceLabel, "Source checks for another device")
        XCTAssertTrue(other.description.contains("candidate")); XCTAssertTrue(event.description.contains("not confirmed"))
    }
    func testCapabilityAndTypedBooleansAreNotGuessed() throws {
        let absent: ReminderList = try ReminderFixture.decode(["items": []])
        XCTAssertNil(absent.remindersSupported)
        XCTAssertThrowsError(try ReminderFixture.decode(["items": [], "remindersSupported": "true"], as: ReminderList.self))
        var event = ReminderFixture.event(); event["candidateOnly"] = "false"
        XCTAssertThrowsError(try ReminderFixture.decode(event, as: ReminderEvent.self))
    }
    func testActualRequestBuilderKeepsOriginalProfileHeadersAndOpaqueCursor() throws {
        let original = ReminderFixture.context()
        let request = try APIClient.reminderRequest(original, method: "GET", suffix: "reminder-events", query: ["limit": "25", "unread": "true", "cursor": "opaque+/="])
        XCTAssertEqual(request.url?.path, "/proxy/api/users/original/reminder-events")
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "cursor" }?.value, "opaque+/=")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Unlock"), "synthetic-original")
        XCTAssertFalse(request.url?.absoluteString.contains("synthetic-token") ?? true)
        XCTAssertNil(request.httpBody)
    }
    func testFalseEventChangesAreExplicitAndInvalidEmptyMutationIsRejected() throws {
        let body = try APIClient.reminderEventBody(read: false, dismissed: false)
        XCTAssertEqual(body["read"] as? Bool, false); XCTAssertEqual(body["dismissed"] as? Bool, false)
        XCTAssertThrowsError(try APIClient.reminderEventBody(read: nil, dismissed: nil))
    }
    func testActualReloadRequestReadsOriginalMetadataWithoutPreparationRoute() throws {
        for series in [false, true] {
            let subject = try ReminderFixture.subject(series: series)
            let request = try APIClient.reminderTitleRequest(subject, context: ReminderFixture.context())
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.path, series ? "/proxy/api/metadata/series/details" : "/proxy/api/metadata/movies/details")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Unlock"), "synthetic-original")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "titleId" }?.value, subject.target.titleID)
            XCTAssertEqual(query?.first { $0.name == "userId" }?.value, "original")
        }
    }
    func testCreateEchoMustConfirmExactChoiceOriginalTitleAndRequestedContent() throws {
        let subject = try ReminderFixture.subject(), choice = subject.choices[0]
        let saved: Reminder = try ReminderFixture.decode(ReminderFixture.reminder(choice))
        XCTAssertTrue(choice.confirms(saved, requested: choice.contentId, subject: subject))
        XCTAssertFalse(choice.confirms(saved, requested: "tmdb:movie:999", subject: subject))
        XCTAssertFalse(subject.choices[1].confirms(saved, requested: choice.contentId, subject: subject))
    }
    func testConflictingKnownCatalogueIDsCannotAnchorTheOriginalTitle() throws {
        let subject = try ReminderFixture.subject()
        var raw = ReminderFixture.title(); raw["tmdbId"] = 999
        let contradictory: Title = try ReminderFixture.decode(raw)
        XCTAssertFalse(ReminderChoices.sameTitle(subject.target, contradictory))
        XCTAssertThrowsError(try ReminderSubject(target: subject.target, title: contradictory, seasons: []))
    }
}
