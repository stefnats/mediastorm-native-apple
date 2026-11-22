import Foundation
import XCTest
@testable import StrmrTV

/// Controlled consumed API ports, not an executed server-expiry experiment.
@MainActor
private final class ArtworkGalleryRecoveryAPI: ContentArtworkAPI {
    static let freshPoster = "https://images.invalid/fresh-gallery.jpg"
    var context = PersonalTasteFixture.context()
    var events: [String] = []
    var requests: [URLRequest] = []
    var expired = true
    var unknownWrite = false
    var preference = ContentArtworkFixture.preference(poster:"old-confirmed",backdrop:"keep-backdrop")
    var reload: (() async throws -> Title)?
    var preferenceRead: (() async throws -> ContentArtworkPreference)?
    func sourceContext() -> SourceActionContext { context }
    func isCurrent(_ context: SourceActionContext) -> Bool { self.context == context }
    static func title() throws -> Title {
        let original = try ContentArtworkFixture.title()
        return try JSONDecoder().decode(Title.self,from:JSONSerialization.data(withJSONObject:[
            "id":original.id,"name":original.name,"mediaType":"movie",
            "poster":["url":"https://images.invalid/standard.jpg"],"posters":[["url":freshPoster]]]))
    }
    func readAllContentArtwork(_ context: SourceActionContext) async throws -> [ContentArtworkPreference] {
        events.append("read-all"); return [preference]
    }
    func readContentArtwork(_ id: String, context: SourceActionContext) async throws -> ContentArtworkPreference {
        events.append("read-one")
        if let preferenceRead { return try await preferenceRead() }
        return preference
    }
    func reloadContentArtworkTitle(_ title: Title, context: SourceActionContext) async throws -> Title {
        events.append("reload-title")
        requests.append(try APIClient.artworkTitleRequest(title,context:context))
        if let reload { return try await reload() }
        expired = false
        return try Self.title()
    }
    func setContentArtwork(_ title: Title, kind: ContentArtworkKind, url: String?, context: SourceActionContext) async throws -> ContentArtworkPreference {
        events.append("write")
        requests.append(try ContentArtworkWire.request(title,kind:kind,url:url,context:context))
        if unknownWrite { throw URLError(.timedOut) }
        if expired { throw APIError.http(HTTPFailure(status:409,data:Data("reload this title before choosing a picture".utf8))) }
        preference = ContentArtworkFixture.preference(poster:kind == .poster ? url : preference.posterUrl,
            backdrop:kind == .backdrop ? url : preference.backdropUrl)
        return preference
    }
    func model() async throws -> (ContentArtworkModel,PersonalArtworkStore) {
        let store = PersonalArtworkStore(api:self); store.activate(context); await store.waitForRead()
        let model = ContentArtworkModel(title:try ContentArtworkFixture.title(),context:context,api:self,store:store)
        await model.load(); return (model,store)
    }
}

@MainActor
final class ContentArtworkRecoveryTests: XCTestCase {
    func testExpiredGalleryRequiresActualMetadataThenPreferenceReadAndANewExplicitChoice() async throws {
        let api = ArtworkGalleryRecoveryAPI(), (model,store) = try await api.model()
        await model.save(kind:.poster,url:ContentArtworkFixture.poster)
        XCTAssertTrue(model.needsGalleryReload); XCTAssertNil(model.preference); XCTAssertNil(model.confirmation)
        XCTAssertEqual(store.poster("tt123",original:"standard"),"old-confirmed")
        await model.load() // A preference-only read must not pretend to renew the gallery.
        await model.save(kind:.poster,url:ContentArtworkFixture.poster)
        XCTAssertEqual(api.events,["read-all","read-one","write"])
        await model.reloadGallery()
        XCTAssertFalse(model.needsGalleryReload); XCTAssertNotNil(model.preference)
        XCTAssertEqual(api.events,["read-all","read-one","write","reload-title","read-one"])
        XCTAssertTrue(ContentArtworkWire.options(model.title,kind:.poster).contains{$0.url == ArtworkGalleryRecoveryAPI.freshPoster})
        XCTAssertFalse(ContentArtworkWire.options(model.title,kind:.poster).contains{$0.url == ContentArtworkFixture.poster})
        XCTAssertEqual(api.requests.filter{$0.httpMethod == "PUT"}.count,1,"Reload never replays the failed choice")
        await model.save(kind:.poster,url:ContentArtworkFixture.poster)
        XCTAssertEqual(api.requests.filter{$0.httpMethod == "PUT"}.count,1,"An old, undelivered choice stays invalid")
        await model.save(kind:.poster,url:ArtworkGalleryRecoveryAPI.freshPoster)
        XCTAssertEqual(store.poster("tt123",original:"standard"),ArtworkGalleryRecoveryAPI.freshPoster)
        XCTAssertEqual(store.backdrop("tt123",original:"standard-back"),"keep-backdrop")
        let body = try PersonalTasteFixture.body(XCTUnwrap(api.requests.last))
        XCTAssertEqual(Set(body.keys),["contentId","contentType","posterUrl"])
        XCTAssertEqual(body["posterUrl"] as? String,ArtworkGalleryRecoveryAPI.freshPoster)
    }
    func testMetadataFailureOrUnconfirmedPreferenceKeepsOriginalGalleryDisabled() async throws {
        for failure in ["metadata","preference"] {
            let api = ArtworkGalleryRecoveryAPI(), (model,store) = try await api.model(), original = model.title
            await model.save(kind:.poster,url:ContentArtworkFixture.poster)
            if failure == "metadata" { api.reload = { throw URLError(.networkConnectionLost) } }
            else { api.preferenceRead = { throw URLError(.networkConnectionLost) } }
            await model.reloadGallery()
            XCTAssertTrue(model.needsGalleryReload); XCTAssertNil(model.preference); XCTAssertNil(model.confirmation)
            XCTAssertEqual(model.title,original)
            XCTAssertEqual(store.poster("tt123",original:"standard"),"old-confirmed")
            await model.save(kind:.poster,url:ArtworkGalleryRecoveryAPI.freshPoster)
            XCTAssertEqual(api.events.filter{$0 == "write"}.count,1)
            XCTAssertEqual(api.events.filter{$0 == "read-one"}.count,failure == "metadata" ? 1 : 2)
        }
    }
    func testForeignOrContradictoryMetadataCannotRenewChoicesOrReadPreferences() async throws {
        let cases: [[String:Any]] = [
            ["id":"tt999","name":"Wrong","mediaType":"movie"],
            ["id":"tt123","name":"Wrong kind","mediaType":"series"],
            ["id":"tt123","name":"Conflicting provider","mediaType":"movie","tmdbId":99]
        ]
        for fields in cases {
            let api = ArtworkGalleryRecoveryAPI()
            var originalFields: [String:Any] = ["id":"tt123","name":"Synthetic","mediaType":"movie","tmdbId":55,
                "posters":[["url":ContentArtworkFixture.poster]]]
            // Each pair deliberately shares a primary identity only in the latter two cases.
            originalFields["poster"] = ["url":"https://images.invalid/standard.jpg"]
            let original = try JSONDecoder().decode(Title.self,from:JSONSerialization.data(withJSONObject:originalFields))
            let foreign = try JSONDecoder().decode(Title.self,from:JSONSerialization.data(withJSONObject:fields))
            let store = PersonalArtworkStore(api:api), model = ContentArtworkModel(title:original,context:api.context,api:api,store:store)
            await model.load(); await model.save(kind:.poster,url:ContentArtworkFixture.poster)
            api.reload = { foreign }; await model.reloadGallery()
            XCTAssertTrue(model.needsGalleryReload); XCTAssertNil(model.preference); XCTAssertEqual(model.title,original)
            XCTAssertEqual(api.events.filter{$0 == "read-one"}.count,1)
        }
    }
    func testHeldMetadataAfterCloseCancellationOrProfileChangeCannotPublishOrReadAgain() async throws {
        for exit in ["close","cancel","profile"] {
            let api = ArtworkGalleryRecoveryAPI(), (model,store) = try await api.model(), original = model.title
            await model.save(kind:.poster,url:ContentArtworkFixture.poster)
            let entered = XCTestExpectation(description:"Actual gallery reload port entered")
            var pending: CheckedContinuation<Title,Error>?
            api.reload = { try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() } }
            let reload = Task { await model.reloadGallery() }
            let wait = await XCTWaiter.fulfillment(of:[entered],timeout:2); XCTAssertEqual(wait,.completed)
            switch exit {
            case "close": model.close()
            case "cancel": reload.cancel()
            default: api.context = PersonalTasteFixture.context("replacement")
            }
            pending?.resume(returning:try ArtworkGalleryRecoveryAPI.title()); pending = nil; await reload.value
            XCTAssertTrue(model.needsGalleryReload); XCTAssertNil(model.preference); XCTAssertEqual(model.title,original)
            XCTAssertEqual(api.events.filter{$0 == "read-one"}.count,1)
            if exit != "profile" { XCTAssertEqual(store.poster("tt123",original:"standard"),"old-confirmed") }
        }
    }
    func testUnknownWriteRetainsPreferenceOnlyRecoveryAndNeverAutomaticallyReloadsMetadata() async throws {
        let api = ArtworkGalleryRecoveryAPI(), (model,_) = try await api.model()
        api.unknownWrite = true
        await model.save(kind:.poster,url:ContentArtworkFixture.poster)
        XCTAssertFalse(model.needsGalleryReload); XCTAssertNil(model.preference)
        await model.reloadGallery(); XCTAssertFalse(api.events.contains("reload-title"))
        await model.load()
        XCTAssertNotNil(model.preference)
        XCTAssertEqual(api.events,["read-all","read-one","write","read-one"])
    }
    func testActualReloadWireUsesExistingBodylessMetadataRoutesAndOriginalCoordinatesOnly() throws {
        for kind in ["movie","series"] {
            let title = try JSONDecoder().decode(Title.self,from:JSONSerialization.data(withJSONObject:[
                "id":"tmdb:\(kind):55","name":"Synthetic","mediaType":kind,"tmdbId":55,"year":2026]))
            let request = try APIClient.artworkTitleRequest(title,context:PersonalTasteFixture.context())
            XCTAssertEqual(request.httpMethod,"GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.path,"/base/api/metadata/\(kind == "movie" ? "movies" : "series")/details")
            let query = try XCTUnwrap(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems)
            XCTAssertEqual(query.first{$0.name == "titleId"}?.value,title.id)
            XCTAssertEqual(query.first{$0.name == "tmdbId"}?.value,"55")
            XCTAssertEqual(query.first{$0.name == "userId"}?.value,"original")
            XCTAssertEqual(query.first{$0.name == "profileId"}?.value,"original")
            XCTAssertFalse(query.contains{["prequeue","reason","automaticLibrarySelection","resource"].contains($0.name)})
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-session")
            XCTAssertEqual(request.value(forHTTPHeaderField:"X-Profile-Unlock"),"original-proof")
        }
    }
}
