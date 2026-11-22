import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class ContentArtworkFlowTests: XCTestCase {
    func testUnsupportedReadCannotUseLegacyMutationFallback() async throws {
        let api = ContentArtworkTestAPI(); api.supported = false
        let store = await ContentArtworkFixture.store(api)
        let model = ContentArtworkModel(title:try ContentArtworkFixture.title(),context:api.context,api:api,store:store)
        await model.load(); await model.save(kind:.poster,url:ContentArtworkFixture.poster)
        XCTAssertFalse(model.preference?.supported ?? true)
        XCTAssertEqual(api.events,["read-all","read-one"]); XCTAssertNotNil(model.message)
    }
    func testAbsentPreferenceAndPartialSavePreserveOtherConfirmedPicture() async throws {
        let api = ContentArtworkTestAPI(), store = await ContentArtworkFixture.store(api)
        let model = ContentArtworkModel(title:try ContentArtworkFixture.title(),context:api.context,api:api,store:store)
        await model.load(); XCTAssertTrue(model.preference?.supported == true)
        await model.save(kind:.backdrop,url:ContentArtworkFixture.backdrop)
        await model.save(kind:.poster,url:ContentArtworkFixture.poster)
        XCTAssertEqual(model.preference?.choice(.backdrop),ContentArtworkFixture.backdrop)
        XCTAssertEqual(store.poster("tt123",original:"standard"),ContentArtworkFixture.poster)
        await model.save(kind:.poster,url:nil)
        XCTAssertNil(model.preference?.choice(.poster))
        XCTAssertEqual(store.poster("tt123",original:"standard"),"standard")
        XCTAssertEqual(store.backdrop("tt123",original:"standard-back"),ContentArtworkFixture.backdrop)
        XCTAssertEqual(api.events,["read-all","read-one","write-backdropUrl","write-posterUrl","write-posterUrl"])
    }
    func testUndeliveredChoiceNeverReachesAPI() async throws {
        let api = ContentArtworkTestAPI(), store = await ContentArtworkFixture.store(api)
        let model = ContentArtworkModel(title:try ContentArtworkFixture.title(),context:api.context,api:api,store:store)
        await model.load(); await model.save(kind:.poster,url:ContentArtworkFixture.backdrop)
        XCTAssertEqual(api.events,["read-all","read-one"])
    }
    func testUnknownWriteDoesNotReplayOrInstallGuessedChoice() async throws {
        let api = ContentArtworkTestAPI()
        api.values = [ContentArtworkFixture.preference(poster:"old-confirmed")]
        let store = await ContentArtworkFixture.store(api)
        api.write = { _, _, _ in
            api.values = [ContentArtworkFixture.preference(poster:ContentArtworkFixture.poster)]
            throw ContentArtworkTestAPI.Failure.unknownAcknowledgement
        }
        let model = ContentArtworkModel(title:try ContentArtworkFixture.title(),context:api.context,api:api,store:store)
        await model.load(); await model.save(kind:.poster,url:ContentArtworkFixture.poster)
        XCTAssertNil(model.preference); XCTAssertNil(model.confirmation)
        XCTAssertEqual(store.poster("tt123",original:"standard"),"old-confirmed")
        await model.save(kind:.poster,url:ContentArtworkFixture.poster)
        XCTAssertEqual(api.events.filter{$0 == "write-posterUrl"}.count,1)
        await model.load() // Explicit read observes the actual current value.
        XCTAssertEqual(model.preference?.choice(.poster),ContentArtworkFixture.poster)
        XCTAssertEqual(store.poster("tt123",original:"standard"),ContentArtworkFixture.poster)
    }
    func testHeldSaveAfterCloseOrViewerChangeCannotInstallLateReply() async throws {
        for close in [false,true] {
            let api = ContentArtworkTestAPI(), original = api.context
            let store = await ContentArtworkFixture.store(api)
            let entered = XCTestExpectation(description:"Original image save entered")
            var pending: CheckedContinuation<ContentArtworkPreference,Error>?
            api.write = { _, _, _ in try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
            let model = ContentArtworkModel(title:try ContentArtworkFixture.title(),context:original,api:api,store:store)
            await model.load()
            let saving = Task { await model.save(kind:.poster,url:ContentArtworkFixture.poster) }
            let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
            if close { model.close() } else { api.context = PersonalTasteFixture.context("other") }
            pending?.resume(returning:ContentArtworkFixture.preference(poster:ContentArtworkFixture.poster)); pending = nil
            await saving.value
            XCTAssertNil(model.preference); XCTAssertNil(model.confirmation)
            XCTAssertEqual(store.poster("tt123",original:"standard"),"standard")
            XCTAssertEqual(api.events.filter{$0 == "write-posterUrl"}.count,1)
        }
    }
    func testMismatchedReplyCannotConfirmOtherTitleOrChoice() async throws {
        for wrongTitle in [false,true] {
            let api = ContentArtworkTestAPI(), store = await ContentArtworkFixture.store(api)
            api.write = { _, _, _ in
                ContentArtworkFixture.preference(wrongTitle ? "other" : "tt123",poster:"unrequested")
            }
            let model = ContentArtworkModel(title:try ContentArtworkFixture.title(),context:api.context,api:api,store:store)
            await model.load(); await model.save(kind:.poster,url:ContentArtworkFixture.poster)
            XCTAssertNil(model.preference); XCTAssertNil(model.confirmation)
            XCTAssertEqual(store.poster("tt123",original:"standard"),"standard")
        }
    }
    func testNamelessPreferenceCannotSmuggleAnImageIntoConfirmedRead() async throws {
        let api = ContentArtworkTestAPI(), store = await ContentArtworkFixture.store(api)
        api.readOne = { ContentArtworkFixture.preference(nil,poster:"unbound") }
        let model = ContentArtworkModel(title:try ContentArtworkFixture.title(),context:api.context,api:api,store:store)
        await model.load()
        XCTAssertNil(model.preference); XCTAssertEqual(store.poster("tt123",original:"standard"),"standard")
    }
}
