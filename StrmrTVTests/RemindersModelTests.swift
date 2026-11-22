import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class ReminderFixtureAPI: ReminderAPI {
    var context = ReminderFixture.context()
    var adult = true
    var calls: [String] = []
    var list: ReminderList
    var inbox: ReminderInbox
    var holdList = false
    var pendingList: CheckedContinuation<ReminderList, Error>?
    var holdCreate = false
    var pendingCreate: CheckedContinuation<ReminderCreated, Error>?
    var createError: Error?
    var reloadError: Error?
    var holdReload = false
    var pendingReload: CheckedContinuation<ReminderSubject, Error>?
    var markReply: ReminderUpdated?
    init() throws { list = try ReminderFixture.list(); inbox = try ReminderFixture.inbox() }
    func sourceContext() -> SourceActionContext { context }
    func isCurrent(_ context: SourceActionContext) -> Bool { self.context == context }
    func remindersAllowed(_ context: SourceActionContext) -> Bool { adult && isCurrent(context) }
    func reminders(_ context: SourceActionContext) async throws -> ReminderList {
        calls.append("list")
        if holdList { return try await withCheckedThrowingContinuation { pendingList = $0 } }; return list
    }
    func reminderInbox(_ context: SourceActionContext, unread: Bool, cursor: String?) async throws -> ReminderInbox {
        calls.append("inbox:" + (cursor ?? "first")); return inbox
    }
    func createReminder(_ choice: ReminderChoice, context: SourceActionContext) async throws -> ReminderCreated {
        calls.append("create")
        if let createError { throw createError }
        if holdCreate { return try await withCheckedThrowingContinuation { pendingCreate = $0 } }
        return try created(choice)
    }
    func created(_ choice: ReminderChoice) throws -> ReminderCreated {
        try ReminderFixture.decode(["remindersSupported": true, "monitoring": "observations_only", "requestedContentId": choice.contentId, "item": ReminderFixture.reminder(choice)])
    }
    func revokeReminder(_ id: String, context: SourceActionContext) async throws { calls.append("revoke") }
    func markReminderEvent(_ id: String, read: Bool?, dismissed: Bool?, context: SourceActionContext) async throws -> ReminderUpdated {
        calls.append("mark")
        if let markReply { return markReply }
        return try ReminderFixture.decode(["remindersSupported": true, "item": ReminderFixture.event(id: id, read: read == true, dismissed: dismissed == true)])
    }
    func reloadReminderTitle(_ subject: ReminderSubject, context: SourceActionContext) async throws -> ReminderSubject {
        calls.append("reload")
        if let reloadError { throw reloadError }
        if holdReload { return try await withCheckedThrowingContinuation { pendingReload = $0 } }; return subject
    }
}

@MainActor
final class RemindersModelTests: XCTestCase {
    @nonobjc func until(_ predicate: () -> Bool) async { for _ in 0..<1000 where !predicate() { await Task.yield() } }
    private func ready(_ api: ReminderFixtureAPI, subject: ReminderSubject? = nil) async -> RemindersModel {
        let model = RemindersModel(context: api.context, subject: subject, api: api)
        model.load(); await until { !model.busy }; return model
    }
    func testInitializationAndOrdinaryLoadsNeverCreateReminders() async throws {
        let api = try ReminderFixtureAPI(), model = RemindersModel(context: api.context, api: api)
        XCTAssertTrue(api.calls.isEmpty)
        model.load(); await until { !model.busy }
        XCTAssertEqual(api.calls, ["list", "inbox:first"]); XCTAssertTrue(model.supported)
    }
    func testChildOrChangedOriginalContextCannotIssueRequests() async throws {
        let api = try ReminderFixtureAPI(), original = api.context
        api.adult = false
        let child = RemindersModel(context: original, api: api)
        child.load(); XCTAssertTrue(child.closed); XCTAssertTrue(api.calls.isEmpty)
        api.adult = true; api.context = ReminderFixture.context(proof: "renewed")
        let old = RemindersModel(context: original, api: api)
        old.load(); XCTAssertTrue(old.closed); XCTAssertTrue(api.calls.isEmpty)
    }
    func testClosedDialogCannotPublishMaskedLateListOrRequestInbox() async throws {
        let api = try ReminderFixtureAPI(); api.holdList = true
        let model = RemindersModel(context: api.context, api: api)
        model.load(); await until { api.pendingList != nil }
        XCTAssertNotNil(api.pendingList)
        model.close(); api.pendingList?.resume(returning: api.list); api.pendingList = nil
        await until { !model.busy }
        XCTAssertFalse(model.supported); XCTAssertTrue(model.reminders.isEmpty); XCTAssertEqual(api.calls, ["list"])
    }
    func testUnsupportedListDoesNotProbeInboxOrEnableMutation() async throws {
        let api = try ReminderFixtureAPI(); api.list = try ReminderFixture.list(support: false)
        let subject = try ReminderFixture.subject(), model = await ready(api, subject: subject)
        model.create(subject.choices[0])
        XCTAssertFalse(model.supported); XCTAssertEqual(api.calls, ["list"])
    }
    func testLostCreateAcknowledgementRequiresReadAndNeverResends() async throws {
        let api = try ReminderFixtureAPI(), subject = try ReminderFixture.subject(), model = await ready(api, subject: subject)
        api.createError = URLError(.networkConnectionLost)
        model.create(subject.choices[0]); await until { !model.busy }
        model.create(subject.choices[0]); await Task.yield()
        XCTAssertFalse(model.supported); XCTAssertEqual(api.calls.filter { $0 == "create" }.count, 1)
        model.refresh(); await until { !model.busy }
        XCTAssertTrue(model.supported); XCTAssertEqual(api.calls.filter { $0 == "create" }.count, 1)
    }
    func testChangedProfileDuringCreateCannotPublishSuccessOrAdoptNewCredentials() async throws {
        let api = try ReminderFixtureAPI(), subject = try ReminderFixture.subject(), model = await ready(api, subject: subject)
        api.holdCreate = true
        model.create(subject.choices[0]); await until { api.pendingCreate != nil }
        XCTAssertNotNil(api.pendingCreate)
        api.context = ReminderFixture.context("replacement")
        api.pendingCreate?.resume(returning: try api.created(subject.choices[0])); api.pendingCreate = nil
        await until { !model.busy }
        XCTAssertTrue(model.closed); XCTAssertTrue(model.reminders.isEmpty); XCTAssertNil(model.message)
        XCTAssertEqual(api.calls.filter { $0 == "create" }.count, 1)
    }
    func testRevokeRetainsInboxAndMarkReadUnreadDismissUseAcknowledgedEvent() async throws {
        let api = try ReminderFixtureAPI(), model = await ready(api)
        let reminder = try XCTUnwrap(model.reminders.first), originalEvent = try XCTUnwrap(model.events.first)
        model.revoke(reminder); await until { !model.busy }
        XCTAssertTrue(model.reminders.isEmpty); XCTAssertEqual(model.events, [originalEvent])
        model.update(originalEvent, read: true); await until { !model.busy }
        let read = try XCTUnwrap(model.events.first); XCTAssertNotNil(read.readAt)
        model.update(read, read: false); await until { !model.busy }
        let unread = try XCTUnwrap(model.events.first); XCTAssertNil(unread.readAt)
        model.update(unread, dismissed: true); await until { !model.busy }
        XCTAssertTrue(model.events.isEmpty)
    }
    func testWrongAcknowledgedEventCannotUpdateOrEnableAnotherMutation() async throws {
        let api = try ReminderFixtureAPI(), model = await ready(api)
        api.markReply = try ReminderFixture.decode(["remindersSupported": true, "item": ReminderFixture.event(id: "foreign")])
        let event = try XCTUnwrap(model.events.first)
        model.update(event, read: true); await until { !model.busy }
        XCTAssertFalse(model.supported); XCTAssertEqual(model.events, [event])
        model.update(event, dismissed: true); XCTAssertEqual(api.calls.filter { $0 == "mark" }.count, 1)
    }
    func testPaginationDeduplicatesAndCannotLoopOpaqueCursor() async throws {
        let api = try ReminderFixtureAPI(); api.inbox = try ReminderFixture.inbox(cursor: "cursor-one")
        let model = await ready(api)
        api.inbox = try ReminderFixture.inbox(items: [ReminderFixture.event(), ReminderFixture.event(id: "event-two")], cursor: "cursor-two")
        model.more(); await until { !model.busy }
        XCTAssertEqual(model.events.map(\.id), ["event-one", "event-two"])
        api.inbox = try ReminderFixture.inbox(cursor: "cursor-one")
        model.more(); await until { !model.busy }
        XCTAssertFalse(model.supported); XCTAssertNil(model.nextCursor)
        model.more(); XCTAssertEqual(api.calls.filter { $0.hasPrefix("inbox:") }.count, 3)
    }
    func testUnreadFilterReloadsAndAcknowledgedReadRemovesOnlyItsRow() async throws {
        let api = try ReminderFixtureAPI()
        api.inbox = try ReminderFixture.inbox(items: [ReminderFixture.event(), ReminderFixture.event(id: "already-read", read: true)])
        let model = await ready(api)
        XCTAssertEqual(model.events.count, 2)
        model.setUnread(true); await until { !model.busy }
        XCTAssertEqual(model.events.map(\.id), ["event-one"])
        let event = try XCTUnwrap(model.events.first)
        model.update(event, read: true); await until { !model.busy }
        XCTAssertTrue(model.events.isEmpty); XCTAssertTrue(model.supported)
        XCTAssertEqual(api.calls.filter { $0 == "inbox:first" }.count, 2)
    }
    func testInterestLimitOffersManagementInsteadOfRetryingMutation() async throws {
        let api = try ReminderFixtureAPI(), subject = try ReminderFixture.subject(), model = await ready(api, subject: subject)
        api.createError = ReminderFixture.error("reminder_interest_limit")
        model.create(subject.choices[0]); await until { !model.busy }
        XCTAssertEqual(model.recovery, .manage); XCTAssertFalse(model.supported)
    }
}
