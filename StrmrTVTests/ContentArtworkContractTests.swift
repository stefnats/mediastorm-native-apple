import Foundation
import XCTest
@testable import StrmrTV

@MainActor
enum ContentArtworkFixture {
    static let poster = "https://images.invalid/poster-choice.jpg"
    static let backdrop = "https://images.invalid/back-choice.jpg"
    static func title() throws -> Title {
        try JSONDecoder().decode(Title.self,from:Data(#"{"id":"tt123","name":"Synthetic","mediaType":"movie","poster":{"url":"https://images.invalid/standard.jpg"},"textPoster":{"url":"https://images.invalid/text.jpg"},"posters":[{"url":"https://images.invalid/poster-choice.jpg"},{"url":"https://images.invalid/standard.jpg"}],"backdrop":{"url":"https://images.invalid/standard-back.jpg"},"textBackdrop":{"url":"https://images.invalid/text-back.jpg"},"backdrops":[{"url":"https://images.invalid/back-choice.jpg"}]}"#.utf8))
    }
    static func preference(_ id: String? = "tt123", supported: Bool? = true, poster: String? = nil, backdrop: String? = nil) -> ContentArtworkPreference {
        .init(contentId:id,artworkPreferenceSupported:supported,posterUrl:poster,backdropUrl:backdrop)
    }
    static func store(_ api: ContentArtworkTestAPI) async -> PersonalArtworkStore {
        let store = PersonalArtworkStore(api:api)
        store.activate(api.context); await store.waitForRead()
        return store
    }
}

/// Controlled client-state API. The real handler's partial-write behavior is a
/// backend contract; this fixture never claims to prove server authorization.
@MainActor
final class ContentArtworkTestAPI: ContentArtworkAPI {
    enum Failure: Error { case unknownAcknowledgement }
    var context = PersonalTasteFixture.context()
    var values: [ContentArtworkPreference] = []
    var supported = true
    var events: [String] = []
    var contexts: [SourceActionContext] = []
    var readAll: (() async throws -> [ContentArtworkPreference])?
    var readOne: (() async throws -> ContentArtworkPreference)?
    var write: ((Title,ContentArtworkKind,String?) async throws -> ContentArtworkPreference)?
    func sourceContext() -> SourceActionContext { context }
    func isCurrent(_ context: SourceActionContext) -> Bool { context == self.context }
    func readContentArtwork(_ id: String, context: SourceActionContext) async throws -> ContentArtworkPreference {
        events.append("read-one"); contexts.append(context)
        if let readOne { return try await readOne() }
        return values.first { $0.contentId == ContentArtworkWire.key(id) } ?? ContentArtworkFixture.preference(nil,supported:supported)
    }
    func readAllContentArtwork(_ context: SourceActionContext) async throws -> [ContentArtworkPreference] {
        events.append("read-all"); contexts.append(context)
        if let readAll { return try await readAll() }
        return values
    }
    func setContentArtwork(_ title: Title, kind: ContentArtworkKind, url: String?, context: SourceActionContext) async throws -> ContentArtworkPreference {
        events.append("write-\(kind.rawValue)"); contexts.append(context)
        if let write { return try await write(title,kind,url) }
        let id = ContentArtworkWire.key(title.id), old = values.first { $0.contentId == id }
        let next = ContentArtworkFixture.preference(id,supported:supported,
            poster:kind == .poster ? url : old?.posterUrl,backdrop:kind == .backdrop ? url : old?.backdropUrl)
        values.removeAll { $0.contentId == id }; values.append(next)
        return next
    }
}

@MainActor
final class ContentArtworkContractTests: XCTestCase {
    func testActualTitleDecodesDeliveredPosterAndTextBackdropVariants() throws {
        let title = try ContentArtworkFixture.title()
        XCTAssertEqual(title.posters?.count,2)
        XCTAssertEqual(title.textBackdrop?.url,"https://images.invalid/text-back.jpg")
        let choices = ContentArtworkWire.options(title,kind:.poster)
        XCTAssertNil(choices.first?.url)
        XCTAssertEqual(choices.first?.preview,"https://images.invalid/text.jpg")
        XCTAssertEqual(choices.compactMap(\.url),["https://images.invalid/standard.jpg","https://images.invalid/text.jpg",ContentArtworkFixture.poster])
        XCTAssertEqual(ContentArtworkWire.options(title,kind:.backdrop).compactMap(\.url),[
            "https://images.invalid/standard-back.jpg","https://images.invalid/text-back.jpg",ContentArtworkFixture.backdrop])
    }
    func testActualPartialWireContainsOnlyOnePictureFieldAndOriginalHeaders() throws {
        let title = try ContentArtworkFixture.title(), context = PersonalTasteFixture.context()
        let request = try ContentArtworkWire.request(title,kind:.poster,url:ContentArtworkFixture.poster,context:context)
        let fields = try PersonalTasteFixture.body(request)
        XCTAssertEqual(Set(fields.keys),["contentId","contentType","posterUrl"])
        XCTAssertEqual(fields["posterUrl"] as? String,ContentArtworkFixture.poster)
        XCTAssertEqual(request.httpMethod,"PUT")
        XCTAssertEqual(request.url?.path,"/base/api/users/original/content-preferences/artwork")
        XCTAssertEqual(request.value(forHTTPHeaderField:"X-Profile-Unlock"),"original-proof")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-session")
        XCTAssertNil(fields["audioLanguage"]); XCTAssertNil(fields["subtitleMode"]); XCTAssertNil(fields["preferLocalFiles"])
    }
    func testNullResetIsNotEmptyStringOrWholePreferenceDelete() throws {
        let request = try ContentArtworkWire.request(ContentArtworkFixture.title(),kind:.backdrop,url:nil,context:PersonalTasteFixture.context())
        let fields = try PersonalTasteFixture.body(request)
        XCTAssertEqual(Set(fields.keys),["contentId","contentType","backdropUrl"])
        XCTAssertTrue(fields["backdropUrl"] is NSNull)
        XCTAssertEqual(request.httpMethod,"PUT"); XCTAssertNil(fields["posterUrl"])
    }
    func testUndeliveredOrEmptyChoiceCannotGenerateMutation() throws {
        let title = try ContentArtworkFixture.title()
        for url in ["", "https://images.invalid/unlisted.jpg"] {
            XCTAssertThrowsError(try ContentArtworkWire.body(title,kind:.poster,url:url))
        }
        XCTAssertThrowsError(try ContentArtworkWire.body(title,kind:.poster,url:ContentArtworkFixture.backdrop))
    }
    func testMissingCapabilityStaysUnsupportedAndKnownAbsentPreferenceIsLegitimate() throws {
        let legacy = try JSONDecoder().decode(ContentArtworkPreference.self,from:Data(#"{"contentId":"tt123","audioLanguage":"fra"}"#.utf8))
        XCTAssertFalse(legacy.supported); XCTAssertNil(legacy.posterUrl)
        let absent = try JSONDecoder().decode(ContentArtworkPreference.self,from:Data(#"{"artworkPreferenceSupported":true,"localSourcePreferenceSupported":true}"#.utf8))
        XCTAssertTrue(absent.supported); XCTAssertNil(absent.contentId)
        XCTAssertNil(absent.choice(.poster)); XCTAssertNil(absent.choice(.backdrop))
    }
    func testVariantListIsBoundedWithoutAddingArbitraryPictures() throws {
        let raw: [String:Any] = ["id":"bounded","name":"Synthetic","mediaType":"movie",
            "posters":(0..<100).map { ["url":"https://images.invalid/\($0).jpg"] }]
        let title = try JSONDecoder().decode(Title.self,from:JSONSerialization.data(withJSONObject:raw))
        let options = ContentArtworkWire.options(title,kind:.poster)
        XCTAssertEqual(options.count,41); XCTAssertNil(options[0].url)
        XCTAssertEqual(Set(options.compactMap(\.url)).count,40)
    }
    func testOversizedDeliveredURLCannotExceedExistingArtworkBodyLimit() throws {
        let url = "https://images.invalid/" + String(repeating:"x",count:8300)
        let raw: [String:Any] = ["id":"bounded","name":"Synthetic","mediaType":"movie","posters":[["url":url]]]
        let title = try JSONDecoder().decode(Title.self,from:JSONSerialization.data(withJSONObject:raw))
        XCTAssertTrue(ContentArtworkWire.options(title,kind:.poster).contains { $0.url == url })
        XCTAssertThrowsError(try ContentArtworkWire.request(title,kind:.poster,url:url,context:PersonalTasteFixture.context()))
    }
}
