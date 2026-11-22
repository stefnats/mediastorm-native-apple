import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class TasteSetupOfferTests: XCTestCase {
    func testOfferIsOptionalOncePerActivationAndDoesNotMutate() async {
        let api = PersonalTasteTestAPI(), offer = TasteSetupOffer(), activation = UUID()
        let first = await offer.check(context:api.context,activation:activation,api:api,visible:{true})
        XCTAssertEqual(first?.status,"new")
        let again = await offer.check(context:api.context,activation:activation,api:api,visible:{true})
        XCTAssertNil(again); XCTAssertEqual(api.events,["setup-read"])
        let next = await offer.check(context:api.context,activation:UUID(),api:api,visible:{true})
        XCTAssertNotNil(next); XCTAssertEqual(api.events,["setup-read","setup-read"])
    }
    func testFailedOptionalReadDoesNotLoopOrWriteButManualEditorCanRead() async {
        let api = PersonalTasteTestAPI(), offer = TasteSetupOffer(), activation = UUID()
        api.setupRead = { throw PersonalTasteTestAPI.Failure.unknownAcknowledgement }
        let first = await offer.check(context:api.context,activation:activation,api:api,visible:{true})
        let again = await offer.check(context:api.context,activation:activation,api:api,visible:{true})
        XCTAssertNil(first); XCTAssertNil(again); XCTAssertEqual(api.events,["setup-read"])
        api.setupRead = nil
        let manual = TasteSetupModel(context:api.context,api:api)
        await manual.load()
        XCTAssertNotNil(manual.reply); XCTAssertEqual(api.events,["setup-read","setup-read"])
    }
    func testCompletedSkippedUnavailableAndHiddenHomesNeverPresentSetup() async {
        for reply in [PersonalTasteFixture.reply(status:"completed",source:"manual"),
                      PersonalTasteFixture.reply(status:"skipped"),PersonalTasteFixture.reply(available:false,kinds:[])] {
            let api = PersonalTasteTestAPI(); api.setup = reply
            let value = await TasteSetupOffer().check(context:api.context,activation:UUID(),api:api,visible:{true})
            XCTAssertNil(value); XCTAssertEqual(api.events,["setup-read"])
        }
        let api = PersonalTasteTestAPI()
        let value = await TasteSetupOffer().check(context:api.context,activation:UUID(),api:api,visible:{false})
        XCTAssertNil(value); XCTAssertTrue(api.events.isEmpty)
    }
    func testCoveredDuringHeldReadDefersOfferUntilActuallyVisible() async {
        let api = PersonalTasteTestAPI(), offer = TasteSetupOffer(), activation = UUID()
        let entered = XCTestExpectation(description:"Optional read entered")
        var pending: CheckedContinuation<TasteSetupReply,Error>?, visible = true
        api.setupRead = { try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
        let first = Task { await offer.check(context:api.context,activation:activation,api:api,visible:{visible}) }
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        visible = false; pending?.resume(returning:PersonalTasteFixture.reply()); pending = nil
        let hidden = await first.value; XCTAssertNil(hidden)
        api.setupRead = nil; visible = true
        let next = await offer.check(context:api.context,activation:activation,api:api,visible:{visible})
        XCTAssertNotNil(next); XCTAssertEqual(api.events,["setup-read","setup-read"])
    }
    func testOldActivationReadCannotAdoptAfterActualNewProfile() async {
        let api = PersonalTasteTestAPI(), original = api.context, offer = TasteSetupOffer()
        let entered = XCTestExpectation(description:"Old activation read entered")
        var pending: CheckedContinuation<TasteSetupReply,Error>?
        api.setupRead = { try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
        let first = Task { await offer.check(context:original,activation:UUID(),api:api,visible:{true}) }
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        api.context = PersonalTasteFixture.context("replacement"); api.setupRead = nil
        let replacement = await offer.check(context:api.context,activation:UUID(),api:api,visible:{true})
        XCTAssertNotNil(replacement)
        pending?.resume(returning:PersonalTasteFixture.reply()); pending = nil
        let stale = await first.value
        XCTAssertNil(stale); XCTAssertEqual(api.events,["setup-read","setup-read"])
    }
    func testIntroUsesOriginalReadWithoutAnotherRequestAndNoSaveOnAppearance() async {
        let api = PersonalTasteTestAPI(), initial = PersonalTasteFixture.reply()
        let model = TasteSetupModel(context:api.context,initial:initial,intro:true,api:api)
        await model.load()
        XCTAssertTrue(model.intro); XCTAssertEqual(model.reply,initial); XCTAssertTrue(api.events.isEmpty)
        model.close()
        XCTAssertTrue(api.events.isEmpty)
    }
}
