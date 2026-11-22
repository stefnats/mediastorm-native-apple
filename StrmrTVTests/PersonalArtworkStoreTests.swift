import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class PersonalArtworkStoreTests: XCTestCase {
    func testKnownSaveAndResetChangeOnlyOneTitlesDisplayOverlay() async {
        let api = ContentArtworkTestAPI()
        api.values = [ContentArtworkFixture.preference(poster:"old",backdrop:"old-back"),ContentArtworkFixture.preference("other",poster:"other-poster")]
        let store = await ContentArtworkFixture.store(api)
        let next = ContentArtworkFixture.preference(poster:ContentArtworkFixture.poster,backdrop:"old-back")
        store.confirmSaved(api.context,titleID:"tt123",value:next)
        XCTAssertEqual(store.poster("tt123",original:"standard"),ContentArtworkFixture.poster)
        XCTAssertEqual(store.backdrop("tt123",original:"standard-back"),"old-back")
        XCTAssertEqual(store.poster("other",original:"other-standard"),"other-poster")
        store.confirmSaved(api.context,titleID:"tt123",value:ContentArtworkFixture.preference(backdrop:"old-back"))
        XCTAssertEqual(store.poster("tt123",original:"standard"),"standard")
        XCTAssertEqual(store.backdrop("tt123",original:"standard-back"),"old-back")
    }
    func testHeldAllReadCannotOverwriteNewerConfirmedSave() async {
        let api = ContentArtworkTestAPI(), entered = XCTestExpectation(description:"All-picture read entered")
        var pending: CheckedContinuation<[ContentArtworkPreference],Error>?
        api.readAll = { try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
        let store = PersonalArtworkStore(api:api)
        store.activate(api.context)
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        store.confirmSaved(api.context,titleID:"tt123",value:ContentArtworkFixture.preference(poster:"new-confirmed"))
        pending?.resume(returning:[ContentArtworkFixture.preference(poster:"old-read")]); pending = nil
        await store.waitForRead()
        XCTAssertEqual(store.poster("tt123",original:"standard"),"new-confirmed")
    }
    func testOldProfileReadRemainsOwnedAndCannotRepopulateAfterSwitch() async {
        let api = ContentArtworkTestAPI(), original = api.context
        let entered = XCTestExpectation(description:"A read entered"), joined = XCTestExpectation(description:"A waiter entered")
        var pending: CheckedContinuation<[ContentArtworkPreference],Error>?
        api.readAll = { try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
        let store = PersonalArtworkStore(api:api); store.activate(original)
        let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
        let oldRead = Task { joined.fulfill(); await store.waitForRead() }
        let waiter = await XCTWaiter.fulfillment(of:[joined],timeout:2); XCTAssertEqual(waiter,.completed)
        api.context = PersonalTasteFixture.context("replacement"); api.readAll = nil
        api.values = [ContentArtworkFixture.preference(poster:"B")]
        store.activate(api.context); await store.waitForRead()
        pending?.resume(returning:[ContentArtworkFixture.preference(poster:"A")]); pending = nil
        await oldRead.value
        XCTAssertEqual(store.poster("tt123",original:"standard"),"B")
        store.confirmSaved(original,titleID:"tt123",value:ContentArtworkFixture.preference(poster:"late-A"))
        XCTAssertEqual(store.poster("tt123",original:"standard"),"B")
    }
    func testClearMasksPicturesEvenBeforeAnotherNetworkResponse() async {
        let api = ContentArtworkTestAPI(); api.values = [ContentArtworkFixture.preference(poster:"private-A")]
        let store = await ContentArtworkFixture.store(api)
        XCTAssertEqual(store.poster("tt123",original:"standard"),"private-A")
        store.clear()
        XCTAssertEqual(store.poster("tt123",original:"standard"),"standard")
        store.confirmSaved(api.context,titleID:"tt123",value:ContentArtworkFixture.preference(poster:"late"))
        XCTAssertEqual(store.poster("tt123",original:"standard"),"standard")
    }
    func testAlreadyConfirmedDisplaySurvivesProofRefreshButMasksOtherViewer() async {
        let api = ContentArtworkTestAPI(); api.values = [ContentArtworkFixture.preference(poster:"confirmed")]
        let store = await ContentArtworkFixture.store(api)
        api.context = PersonalTasteFixture.context(proof:"renewed-proof")
        XCTAssertEqual(store.poster("tt123",original:"standard"),"confirmed")
        api.context = PersonalTasteFixture.context("other")
        XCTAssertEqual(store.poster("tt123",original:"standard"),"standard")
    }
    func testLateSingleReadCannotReplaceNewerConfirmedField() async {
        let api = ContentArtworkTestAPI(), store = await ContentArtworkFixture.store(api)
        let revision = store.revision
        store.confirmSaved(api.context,titleID:"tt123",value:ContentArtworkFixture.preference(poster:"new"))
        store.confirmRead(api.context,titleID:"tt123",readRevision:revision,value:ContentArtworkFixture.preference(poster:"old"))
        XCTAssertEqual(store.poster("tt123",original:"standard"),"new")
    }
    func testOutOfOrderPartialAcknowledgementPreservesNewerOppositeField() async {
        let api = ContentArtworkTestAPI()
        api.values = [ContentArtworkFixture.preference(poster:"old-poster",backdrop:"old-back")]
        let store = await ContentArtworkFixture.store(api)
        store.confirmSaved(api.context,titleID:"tt123",value:ContentArtworkFixture.preference(poster:"new-poster",backdrop:"new-back"),kind:.backdrop)
        store.confirmSaved(api.context,titleID:"tt123",value:ContentArtworkFixture.preference(poster:"new-poster",backdrop:"old-back"),kind:.poster)
        XCTAssertEqual(store.poster("tt123",original:"standard"),"new-poster")
        XCTAssertEqual(store.backdrop("tt123",original:"standard-back"),"new-back")
    }
}
