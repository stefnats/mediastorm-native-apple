import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class TasteSetupFlowTests: XCTestCase {
    func testChoicesStayLocalUntilExplicitDoneAndCancelDoesNotSave() async throws {
        let api = PersonalTasteTestAPI(), title = try PersonalTasteFixture.title()
        api.candidateRead = { _, _ in [title] }
        let model = TasteSetupModel(context:api.context,api:api)
        await model.load(); await model.search(kind:"movie",query:"")
        model.toggle(title)
        XCTAssertEqual(model.selected,[title]); XCTAssertTrue(api.setup.titles.isEmpty)
        XCTAssertEqual(api.events,["setup-read","candidates-movie-"])
        model.close(); await model.finish()
        XCTAssertTrue(api.setup.titles.isEmpty); XCTAssertEqual(api.events.count,2)
    }
    func testSaveEmptySkipHistoryAndResetAreSeparateExplicitActions() async throws {
        let title = try PersonalTasteFixture.title(), api = PersonalTasteTestAPI()
        api.setup = PersonalTasteFixture.reply(status:"completed",source:"manual",titles:[title],history:true)
        let save = TasteSetupModel(context:api.context,api:api)
        await save.load(); save.clearSelection(); await save.finish()
        XCTAssertTrue(save.finished); XCTAssertTrue(api.setup.titles.isEmpty); XCTAssertEqual(api.setup.source,"manual")
        api.setup = PersonalTasteFixture.reply(status:"completed",source:"manual",titles:[title],history:true)
        let skip = TasteSetupModel(context:api.context,api:api)
        await skip.load(); await skip.finish(action:"skip")
        XCTAssertEqual(api.setup.status,"skipped"); XCTAssertEqual(api.setup.titles,[title])
        api.setupWrite = { action, titles in
            XCTAssertEqual(action,"history"); XCTAssertTrue(titles.isEmpty)
            return PersonalTasteFixture.reply(status:"completed",source:"history",titles:[title])
        }
        let history = TasteSetupModel(context:api.context,api:api)
        await history.load(); await history.finish(action:"history")
        XCTAssertEqual(history.reply?.source,"history"); XCTAssertTrue(history.finished)
        let reset = TasteSetupModel(context:api.context,api:api)
        await reset.load(); await reset.finish(reset:true)
        XCTAssertEqual(reset.reply?.status,"new"); XCTAssertTrue(reset.selected.isEmpty)
        XCTAssertEqual(api.events.filter{$0 != "setup-read"},["setup-save","setup-skip","setup-history","setup-delete"])
    }
    func testFortyTitleLimitAndAliasDedupUseOnlyDeliveredCandidates() async throws {
        let api = PersonalTasteTestAPI()
        let initial = try (0..<40).map { try PersonalTasteFixture.title("title-\($0)",tmdb:$0+1) }
        api.setup = PersonalTasteFixture.reply(titles:initial)
        let alias = try PersonalTasteFixture.title("alias",tmdb:1), extra = try PersonalTasteFixture.title("extra")
        api.candidateRead = { _, _ in [alias,extra] }
        let model = TasteSetupModel(context:api.context,api:api)
        await model.load(); await model.search(kind:"movie",query:"")
        model.toggle(extra)
        XCTAssertEqual(model.selected.count,40); XCTAssertNotNil(model.message)
        model.toggle(alias); XCTAssertEqual(model.selected.count,39); XCTAssertFalse(model.contains(initial[0]))
        model.toggle(extra); XCTAssertEqual(model.selected.count,40)
        model.toggle(try PersonalTasteFixture.title("not-delivered")); XCTAssertEqual(model.selected.count,40)
    }
    func testLateOlderSearchCannotReplaceNewQueryOrSelectedTitles() async throws {
        let api = PersonalTasteTestAPI(), entered = XCTestExpectation(description:"First search entered")
        let old = try PersonalTasteFixture.title("old"), new = try PersonalTasteFixture.title("new")
        var pending: CheckedContinuation<[Title],Error>?
        api.candidateRead = { _, query in
            if query == "old" { return try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
            return [new]
        }
        let model = TasteSetupModel(context:api.context,api:api)
        await model.load()
        let first = Task { await model.search(kind:"movie",query:"old") }
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        await model.search(kind:"movie",query:"new"); model.toggle(new)
        pending?.resume(returning:[old]); pending = nil
        await first.value
        XCTAssertEqual(model.candidates,[new]); XCTAssertEqual(model.selected,[new])
    }
    func testHeldSaveAfterCloseCannotPublishAndNeverReplays() async throws {
        let api = PersonalTasteTestAPI(), entered = XCTestExpectation(description:"Original setup write entered")
        var pending: CheckedContinuation<TasteSetupReply,Error>?, publications = 0
        api.setupWrite = { _, _ in try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
        let model = TasteSetupModel(context:api.context,api:api,onSaved:{_ in publications += 1})
        await model.load()
        let saving = Task { await model.finish() }
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        model.close(); pending?.resume(returning:PersonalTasteFixture.reply(status:"completed",source:"manual")); pending = nil
        await saving.value; await model.finish()
        XCTAssertFalse(model.finished); XCTAssertEqual(publications,0)
        XCTAssertEqual(api.events,["setup-read","setup-save"])
    }
    func testUnknownWriteOrWrongStatusRequiresReadBeforeAnotherChoice() async throws {
        for wrongStatus in [false,true] {
            let api = PersonalTasteTestAPI()
            api.setupWrite = { _, _ in
                if wrongStatus { return PersonalTasteFixture.reply(status:"skipped") }
                throw PersonalTasteTestAPI.Failure.unknownAcknowledgement
            }
            let model = TasteSetupModel(context:api.context,api:api)
            await model.load(); await model.finish(); await model.finish(action:"skip")
            XCTAssertFalse(model.finished); XCTAssertNil(model.reply); XCTAssertNotNil(model.message)
            XCTAssertEqual(api.events,["setup-read","setup-save"])
            api.setupWrite = nil
            await model.load(); await model.finish()
            XCTAssertTrue(model.finished)
        }
    }
    func testMediaAvailabilityAndHistoryGateAreConsumedBeforeRequests() async throws {
        let api = PersonalTasteTestAPI(); api.setup = PersonalTasteFixture.reply(kinds:["series"])
        let model = TasteSetupModel(context:api.context,api:api)
        await model.load(); await model.search(kind:"movie",query:""); await model.finish(action:"history")
        XCTAssertEqual(api.events,["setup-read"])
        api.setup = PersonalTasteFixture.reply(available:false,kinds:[])
        await model.load(); await model.finish(); await model.search(kind:"series",query:"")
        XCTAssertEqual(api.events,["setup-read","setup-read"])
        await model.finish(reset:true)
        XCTAssertTrue(model.finished); XCTAssertEqual(api.events.last,"setup-delete")
    }
    func testRenewedProfileProofDuringSearchCannotPublishOldCandidates() async throws {
        let api = PersonalTasteTestAPI(), original = api.context
        let entered = XCTestExpectation(description:"Original search entered")
        var pending: CheckedContinuation<[Title],Error>?
        api.candidateRead = { _, _ in try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
        let model = TasteSetupModel(context:original,api:api)
        await model.load()
        let search = Task { await model.search(kind:"movie",query:"held") }
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        api.context = PersonalTasteFixture.context(proof:"replacement-proof")
        pending?.resume(returning:[try PersonalTasteFixture.title()]); pending = nil
        await search.value
        XCTAssertTrue(model.candidates.isEmpty); XCTAssertNil(model.searchError)
        await model.finish()
        XCTAssertEqual(api.events,["setup-read","candidates-movie-held"])
        XCTAssertTrue(api.contexts.allSatisfy{$0 == original})
    }
}
