import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class TitleRatingFlowTests: XCTestCase {
    func testReadSelectionCancelNeverWritesAndConfirmedSavePublishesOnce() async throws {
        let api = PersonalTasteTestAPI(), target = DetailsTarget(try PersonalTasteFixture.title())
        var publications = 0
        let model = TitleRatingModel(target:target,context:api.context,api:api,onSaved:{ _ in publications += 1 })
        await model.load(); model.selected = .love
        XCTAssertEqual(api.events,["rating-read"]); XCTAssertEqual(api.rating,.none)
        await model.save()
        await model.save()
        XCTAssertEqual(model.rating,.love); XCTAssertEqual(api.rating,.love); XCTAssertTrue(model.saved)
        XCTAssertEqual(publications,1); XCTAssertEqual(api.contexts,[api.context,api.context])
        let cancelled = TitleRatingModel(target:target,context:api.context,api:api)
        await cancelled.load(); cancelled.selected = .dislike; cancelled.close(); await cancelled.save()
        XCTAssertEqual(api.rating,.love); XCTAssertEqual(api.events.filter{$0 == "rating-dislike"}.count,0)
    }
    func testHeldSaveAfterProfileChangeCannotPublishOrRepeatAsNewViewer() async throws {
        let api = PersonalTasteTestAPI(), original = api.context
        let entered = XCTestExpectation(description:"Original rating write entered")
        var pending: CheckedContinuation<PersonalTitleRating,Error>?, publications = 0
        api.rateWrite = { _ in try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
        let model = TitleRatingModel(target:DetailsTarget(try PersonalTasteFixture.title()),context:original,api:api,onSaved:{_ in publications += 1})
        await model.load(); model.selected = .like
        let saving = Task { await model.save() }
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        api.context = PersonalTasteFixture.context("replacement")
        pending?.resume(returning:.like); pending = nil
        await saving.value
        XCTAssertNil(model.rating); XCTAssertFalse(model.saved); XCTAssertEqual(publications,0)
        await model.save(); XCTAssertEqual(api.events,["rating-read","rating-like"])
        XCTAssertTrue(api.contexts.allSatisfy{$0 == original})
    }
    func testHeldReadAfterCloseDoesNotAdoptRating() async throws {
        let api = PersonalTasteTestAPI(), entered = XCTestExpectation(description:"Original read entered")
        var pending: CheckedContinuation<PersonalTitleRating,Error>?
        api.rateRead = { try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
        let model = TitleRatingModel(target:DetailsTarget(try PersonalTasteFixture.title()),context:api.context,api:api)
        let loading = Task { await model.load() }
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        model.close(); pending?.resume(returning:.love); pending = nil
        await loading.value
        XCTAssertNil(model.rating); XCTAssertFalse(model.saved)
    }
    func testUnknownWriteRequiresExplicitReadBeforeAnyFurtherSave() async throws {
        let api = PersonalTasteTestAPI()
        api.rateWrite = { _ in throw PersonalTasteTestAPI.Failure.unknownAcknowledgement }
        let model = TitleRatingModel(target:DetailsTarget(try PersonalTasteFixture.title()),context:api.context,api:api)
        await model.load(); model.selected = .dislike; await model.save()
        XCTAssertNil(model.rating); XCTAssertNotNil(model.message); XCTAssertFalse(model.saved)
        await model.save(); XCTAssertEqual(api.events,["rating-read","rating-dislike"])
        api.rateWrite = nil
        await model.load(); await model.save()
        XCTAssertEqual(model.rating,PersonalTitleRating.none); XCTAssertEqual(api.events.last,"rating-none")
    }
    func testMismatchedAcknowledgementIsNotSaved() async throws {
        let api = PersonalTasteTestAPI(); api.rateWrite = { _ in .dislike }
        let model = TitleRatingModel(target:DetailsTarget(try PersonalTasteFixture.title()),context:api.context,api:api)
        await model.load(); model.selected = .love; await model.save()
        XCTAssertNil(model.rating); XCTAssertFalse(model.saved)
        XCTAssertEqual(api.events,["rating-read","rating-love"])
    }
}
