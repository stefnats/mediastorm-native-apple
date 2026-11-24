import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class PictureStyleTests: XCTestCase {
    private func style(profile: String = "original", enabled: Bool = false, posters: Int = 0, backgrounds: Int = 0) -> PictureStyleState {
        .init(profileId:profile,supported:true,enabled:enabled,minimumSamples:3,maxSamples:128,
              posterSamples:posters,backdropSamples:backgrounds)
    }

    func testLegacyServerKeepsManualEditorAvailableWithoutEnablingLearning() async throws {
        let api = ContentArtworkTestAPI(), title = try ContentArtworkFixture.title()
        let model = ContentArtworkModel(title:title,context:api.context,api:api,store:await ContentArtworkFixture.store(api))
        await model.load()
        XCTAssertTrue(model.preference?.supported == true)
        XCTAssertNil(model.pictureStyle)
        await model.save(kind:.poster,url:ContentArtworkFixture.poster)
        XCTAssertEqual(api.values.first?.posterUrl,ContentArtworkFixture.poster)
    }

    func testExplicitOptInAndForgetPreserveManualPicture() async throws {
        let api = ContentArtworkTestAPI(), title = try ContentArtworkFixture.title()
        api.values = [ContentArtworkFixture.preference(poster:ContentArtworkFixture.poster)]
        var state = style(posters:3)
        var writes = 0
        api.readStyle = { state }
        api.writeStyle = { enabled, reset in
            writes += 1
            state = self.style(enabled:reset ? false : enabled!,posters:reset ? 0 : state.posterSamples)
            return state
        }
        let model = ContentArtworkModel(title:title,context:api.context,api:api,store:await ContentArtworkFixture.store(api))
        await model.load()
        XCTAssertEqual(writes,0); XCTAssertFalse(try XCTUnwrap(model.pictureStyle).enabled)
        await model.updatePictureStyle(enabled:true)
        XCTAssertTrue(try XCTUnwrap(model.pictureStyle).enabled)
        await model.updatePictureStyle(enabled:nil,reset:true)
        XCTAssertEqual(writes,2)
        XCTAssertEqual(model.pictureStyle?.posterSamples,0)
        XCTAssertFalse(try XCTUnwrap(model.pictureStyle).enabled)
        XCTAssertEqual(api.values.first?.posterUrl,ContentArtworkFixture.poster)
    }

    func testWrongProfileAcknowledgementRequiresExplicitReloadWithoutRetry() async throws {
        let api = ContentArtworkTestAPI(), title = try ContentArtworkFixture.title()
        api.readStyle = { self.style() }
        var writes = 0
        api.writeStyle = { _,_ in writes += 1; return self.style(profile:"other",enabled:true) }
        let model = ContentArtworkModel(title:title,context:api.context,api:api,store:await ContentArtworkFixture.store(api))
        await model.load(); await model.updatePictureStyle(enabled:true)
        XCTAssertNil(model.pictureStyle); XCTAssertNil(model.confirmation)
        XCTAssertNotNil(model.pictureStyleMessage)
        await model.updatePictureStyle(enabled:true)
        XCTAssertEqual(writes,1)
        await model.load(); XCTAssertNotNil(model.pictureStyle)
    }

    func testHeldWriteCannotUpdateEditorAfterProfileChanges() async throws {
        let api = ContentArtworkTestAPI(), title = try ContentArtworkFixture.title()
        api.readStyle = { self.style() }
        var pending: CheckedContinuation<PictureStyleState,Error>?
        api.writeStyle = { _,_ in try await withCheckedThrowingContinuation { pending = $0 } }
        let model = ContentArtworkModel(title:title,context:api.context,api:api,store:await ContentArtworkFixture.store(api))
        await model.load()
        let task = Task { await model.updatePictureStyle(enabled:true) }
        while pending == nil { await Task.yield() }
        api.context = PersonalTasteFixture.context("other")
        pending?.resume(returning:style(enabled:true))
        await task.value
        XCTAssertNil(model.pictureStyle); XCTAssertNil(model.confirmation)
    }

    func testImpossibleEvidenceAndUnconfirmedResetAreRejected() throws {
        XCTAssertThrowsError(try style(posters:129).validated(profileID:"original"))
        XCTAssertThrowsError(try style(posters:100,backgrounds:100).validated(profileID:"original"))
        XCTAssertThrowsError(try PictureStyleWire.confirmed(style(enabled:true),enabled:nil,reset:true))
        XCTAssertThrowsError(try PictureStyleWire.confirmed(style(posters:1),enabled:nil,reset:true))
        XCTAssertThrowsError(try PictureStyleWire.body(enabled:true,reset:true))
    }

    func testLearnedTitleKeepsOriginalStandardPreviewAndDeliveredManualVariants() throws {
        let title = try JSONDecoder().decode(Title.self, from: Data(#"{"id":"tt123","name":"Synthetic learned title","mediaType":"movie","poster":{"url":"https://images.invalid/learned.jpg"},"textPoster":{"url":"https://images.invalid/learned.jpg"},"standardPoster":{"url":"https://images.invalid/original-text.jpg"},"posters":[{"url":"https://images.invalid/original.jpg"},{"url":"https://images.invalid/original-text.jpg"}],"backdrop":{"url":"https://images.invalid/learned-back.jpg"},"standardBackdrop":{"url":"https://images.invalid/original-back.jpg"},"backdrops":[{"url":"https://images.invalid/original-back.jpg"},{"url":"https://images.invalid/other-back.jpg"}]}"#.utf8))
        XCTAssertEqual(title.standardPoster?.url, "https://images.invalid/original-text.jpg")
        XCTAssertEqual(title.standardBackdrop?.url, "https://images.invalid/original-back.jpg")
        let posters = ContentArtworkWire.options(title, kind: .poster)
        let backgrounds = ContentArtworkWire.options(title, kind: .backdrop)
        XCTAssertNil(posters.first?.url)
        XCTAssertEqual(posters.first?.preview, title.standardPoster?.url)
        XCTAssertNil(backgrounds.first?.url)
        XCTAssertEqual(backgrounds.first?.preview, title.standardBackdrop?.url)
        XCTAssertEqual(posters.dropFirst().compactMap(\.url), [
            "https://images.invalid/learned.jpg", "https://images.invalid/original.jpg", "https://images.invalid/original-text.jpg"])
        XCTAssertEqual(backgrounds.dropFirst().compactMap(\.url), [
            "https://images.invalid/learned-back.jpg", "https://images.invalid/original-back.jpg", "https://images.invalid/other-back.jpg"])
        let reset = try ContentArtworkWire.body(title, kind: .poster, url: nil)
        XCTAssertTrue(reset["posterUrl"] is NSNull)
        XCTAssertNil(reset["backdropUrl"])
        let legacy = try ContentArtworkFixture.title()
        XCTAssertNil(legacy.standardPoster); XCTAssertNil(legacy.standardBackdrop)
        XCTAssertEqual(ContentArtworkWire.options(legacy, kind: .poster).first?.preview, legacy.textPoster?.url)
        XCTAssertEqual(ContentArtworkWire.options(legacy, kind: .backdrop).first?.preview, legacy.backdrop?.url)
    }

    private func learnedTitle() throws -> Title {
        try JSONDecoder().decode(Title.self, from: Data(#"{"id":"tt123","name":"Synthetic cached learned title","mediaType":"movie","poster":{"url":"https://images.invalid/learned.jpg"},"standardPoster":{"url":"https://images.invalid/original.jpg"},"posters":[{"url":"https://images.invalid/poster-choice.jpg"}],"backdrop":{"url":"https://images.invalid/learned-back.jpg"},"standardBackdrop":{"url":"https://images.invalid/original-back.jpg"}}"#.utf8))
    }

    func testConfirmedStandardResetUpdatesCachedDisplayWithoutInventingServerURL() async throws {
        let api = ContentArtworkTestAPI(), title = try learnedTitle()
        let store = await ContentArtworkFixture.store(api)
        let model = ContentArtworkModel(title:title,context:api.context,api:api,store:store)
        await model.load()
        XCTAssertEqual(store.poster(title.id,original:title.poster?.url),title.poster?.url)
        await model.save(kind:.poster,url:nil)
        XCTAssertNil(api.values.first?.posterUrl)
        XCTAssertEqual(store.poster(title.id,original:title.poster?.url),title.standardPoster?.url)
        let legacyAPI = ContentArtworkTestAPI(), legacy = try ContentArtworkFixture.title()
        let legacyStore = await ContentArtworkFixture.store(legacyAPI)
        let legacyModel = ContentArtworkModel(title:legacy,context:legacyAPI.context,api:legacyAPI,store:legacyStore)
        await legacyModel.load(); await legacyModel.save(kind:.poster,url:nil)
        XCTAssertNil(legacyAPI.values.first?.posterUrl)
        XCTAssertEqual(legacyStore.poster(legacy.id,original:legacy.poster?.url),legacy.poster?.url)
    }

    func testManualReplacementClearsOnlyItsOwnStandardDisplay() async throws {
        let api = ContentArtworkTestAPI(), title = try learnedTitle()
        let store = await ContentArtworkFixture.store(api)
        let model = ContentArtworkModel(title:title,context:api.context,api:api,store:store)
        await model.load()
        await model.save(kind:.poster,url:nil); await model.save(kind:.backdrop,url:nil)
        XCTAssertEqual(store.poster(title.id,original:title.poster?.url),title.standardPoster?.url)
        XCTAssertEqual(store.backdrop(title.id,original:title.backdrop?.url),title.standardBackdrop?.url)
        await model.save(kind:.poster,url:ContentArtworkFixture.poster)
        XCTAssertEqual(api.values.first?.posterUrl,ContentArtworkFixture.poster)
        XCTAssertNil(api.values.first?.backdropUrl)
        XCTAssertEqual(store.poster(title.id,original:title.poster?.url),ContentArtworkFixture.poster)
        XCTAssertEqual(store.backdrop(title.id,original:title.backdrop?.url),title.standardBackdrop?.url)
        let staleOpposite = ContentArtworkFixture.preference(poster:ContentArtworkFixture.poster,backdrop:"stale-opposite-field")
        store.confirmSaved(api.context,titleID:title.id,value:staleOpposite,kind:.poster)
        XCTAssertEqual(store.backdrop(title.id,original:title.backdrop?.url),title.standardBackdrop?.url)
    }

    func testStandardDisplayRejectsLateReadAndDoesNotCrossProfileActivation() async throws {
        let api = ContentArtworkTestAPI(), title = try learnedTitle()
        let original = api.context, store = await ContentArtworkFixture.store(api)
        let model = ContentArtworkModel(title:title,context:original,api:api,store:store)
        await model.load()
        let oldRevision = store.revision
        await model.save(kind:.poster,url:nil)
        store.replaceConfirmedRead(original,readRevision:oldRevision,values:[])
        XCTAssertEqual(store.poster(title.id,original:title.poster?.url),title.standardPoster?.url)
        let currentRevision = store.revision
        store.replaceConfirmedRead(original,readRevision:currentRevision,values:[])
        store.replaceConfirmedRead(original,readRevision:currentRevision,values:[ContentArtworkFixture.preference()])
        XCTAssertEqual(store.poster(title.id,original:"fresh-automatic-picture"),"fresh-automatic-picture")
        api.context = PersonalTasteFixture.context("other")
        XCTAssertEqual(store.poster(title.id,original:"other-profile-default"),"other-profile-default")
        api.values = []; store.activate(api.context); await store.waitForRead()
        store.confirmSaved(original,titleID:title.id,value:ContentArtworkFixture.preference(),kind:.poster,standardURL:title.standardPoster?.url)
        store.replaceConfirmedRead(original,readRevision:oldRevision,values:[ContentArtworkFixture.preference()])
        XCTAssertEqual(store.poster(title.id,original:"other-profile-default"),"other-profile-default")
        XCTAssertTrue(api.values.isEmpty)
    }
}
