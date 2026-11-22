import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class ReminderNavigationTests: XCTestCase {
    private func until(_ predicate: () -> Bool) async { for _ in 0..<1000 where !predicate() { await Task.yield() } }
    func testActualInboxDestinationOnlyRequestsBrowsingWithoutPrewarmOrAutoplay() async throws {
        let api = try ReminderFixtureAPI(), model = RemindersModel(context: api.context, api: api)
        model.load(); await until { !model.busy }
        let event = try XCTUnwrap(model.events.first), destination = try XCTUnwrap(model.open(event))
        XCTAssertEqual(destination.target.titleID, event.contentId)
        XCTAssertEqual(destination.context, api.context); XCTAssertFalse(destination.automaticallyPrewarm)
        XCTAssertEqual(api.calls, ["list", "inbox:first"], "Opening a title admits no preparation/search/history operation")
        // Root's separate actual Details router must consume this flag. This
        // source test alone is not proof of the later UI integration or decoder.
    }
    func testLateOrCopiedForeignEventCannotCreateDestination() async throws {
        let api = try ReminderFixtureAPI(), model = RemindersModel(context: api.context, api: api)
        model.load(); await until { !model.busy }
        let foreign: ReminderEvent = try ReminderFixture.decode(ReminderFixture.event(id: "foreign"))
        XCTAssertNil(model.open(foreign))
        let event = try XCTUnwrap(model.events.first)
        api.context = ReminderFixture.context("replacement")
        XCTAssertNil(model.open(event)); XCTAssertEqual(api.calls, ["list", "inbox:first"])
    }
    func testMetadataReloadWaitsForActualOriginalReplyAndNeverReplaysCreate() async throws {
        let api = try ReminderFixtureAPI(), subject = try ReminderFixture.subject(), model = RemindersModel(context: api.context, subject: subject, api: api)
        model.load(withInbox: false); await until { !model.busy }
        api.createError = ReminderFixture.error("reminder_metadata_reload_required")
        model.create(subject.choices[0]); await until { !model.busy }
        XCTAssertEqual(model.recovery, .reloadTitle)
        api.holdReload = true
        model.reloadTitle(); await until { api.pendingReload != nil }
        XCTAssertNotNil(api.pendingReload); XCTAssertFalse(model.supported)
        XCTAssertEqual(api.calls.last, "reload")
        api.pendingReload?.resume(returning: subject); api.pendingReload = nil
        await until { !model.busy }
        XCTAssertTrue(model.supported); XCTAssertEqual(api.calls.last, "list")
        XCTAssertEqual(api.calls.filter { $0 == "create" }.count, 1)
    }
    func testFailedOrLateReloadCannotPublishSuccessOrIssueAnotherRead() async throws {
        for close in [false, true] {
            let api = try ReminderFixtureAPI(), subject = try ReminderFixture.subject(), model = RemindersModel(context: api.context, subject: subject, api: api)
            model.load(withInbox: false); await until { !model.busy }
            api.createError = ReminderFixture.error("reminder_metadata_reload_required")
            model.create(subject.choices[0]); await until { !model.busy }
            api.holdReload = true; model.reloadTitle(); await until { api.pendingReload != nil }
            if close { model.close(); api.pendingReload?.resume(returning: subject) }
            else { api.pendingReload?.resume(throwing: URLError(.networkConnectionLost)) }
            api.pendingReload = nil
            await until { !model.busy }
            XCTAssertFalse(model.supported); XCTAssertEqual(api.calls.last, "reload")
            if !close { XCTAssertEqual(model.recovery, .reloadTitle) }
        }
    }
    func testReturnToSameOriginalInboxJoinsOldReadBeforeReopening() async throws {
        let api = try ReminderFixtureAPI(); api.holdList = true
        let model = RemindersModel(context: api.context, api: api)
        model.load(); await until { api.pendingList != nil }
        model.close()
        let old = api.pendingList; api.pendingList = nil; api.holdList = false
        let reopening = Task { await model.appear() }
        await Task.yield(); XCTAssertTrue(model.closed)
        old?.resume(returning: api.list)
        await reopening.value; await until { !model.busy }
        XCTAssertTrue(model.supported); XCTAssertFalse(model.closed)
        XCTAssertEqual(api.calls, ["list", "list", "inbox:first"])
    }
}
