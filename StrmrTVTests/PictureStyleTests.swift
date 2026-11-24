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
}
