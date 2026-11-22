import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class PostPlayNavigationOwnershipTests: XCTestCase {
    private func until(_ predicate: () -> Bool) async {
        for _ in 0..<1000 { if !predicate() { await Task.yield() } }
        XCTAssertTrue(predicate(), "The actual controlled operation must reach its held boundary")
    }
    private func ready(_ api: PostPlayFixtureAPI) async throws -> PostPlayModel {
        let model = PostPlayModel(offer: try PostPlayFixture.offer(), api: api)
        model.load()
        await until { !model.loading }
        XCTAssertTrue(model.current)
        return model
    }
    private func bundle(_ row: PostPlaySuggestion) throws -> DetailsBundle {
        let raw: [String: Any] = [
            "movieDetails": ["id": row.title.id, "name": row.title.name,
                             "mediaType": "movie", "tmdbId": row.title.tmdbId ?? 0],
            "resume": ["position": 30, "duration": 120, "percent": 25, "eligible": true]
        ]
        return try PostPlayFixture.decode(raw)
    }
    private func retireHeld(_ api: PostPlayFixtureAPI, model: PostPlayModel) {
        model.close()
        let pending = Array(api.pendingDetails.values)
        api.pendingDetails.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }

    func testHeldPlayLookupReleasesNavigationAfterConcurrentRatingRefresh() async throws {
        let api = PostPlayFixtureAPI(), model = try await ready(api)
        defer { retireHeld(api, model: model) }
        let originalContext = api.context
        let oldRow = try XCTUnwrap(model.suggestions.first)
        api.holdDetails = true
        let oldLookup = Task { try await model.preparePlay(oldRow) }
        defer { oldLookup.cancel() }
        await until { api.pendingDetails[0] != nil }
        XCTAssertNil(model.details(oldRow))

        // This is the actual enabled rating path while the Play lookup awaits.
        model.rate(.like)
        await until { !model.saving }
        XCTAssertEqual(model.rating, .like)
        let currentRow = try XCTUnwrap(model.suggestions.first)
        XCTAssertFalse(currentRow === oldRow)
        XCTAssertNil(model.details(currentRow))
        try XCTUnwrap(api.pendingDetails.removeValue(forKey: 0)).resume(returning: bundle(oldRow))
        do {
            _ = try await oldLookup.value
            XCTFail("A pre-rating lookup must not adopt its old suggestion")
        } catch { XCTAssertTrue(error.isCancellation) }

        XCTAssertNotNil(model.details(currentRow), "Actual old lookup completion must release its navigation slot")
        api.holdDetails = false
        let next = try await model.preparePlay(currentRow)
        XCTAssertEqual(next.title.titleID, currentRow.title.id)
        XCTAssertEqual(next.start, .seconds(30))
        XCTAssertEqual(api.context, originalContext)
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("details:") }.count, 2)
        XCTAssertEqual(api.calls.filter { $0 == "rate:like" }.count, 1)
    }

    func testOlderPlayLookupCannotReleaseReplacementNavigationAfterReload() async throws {
        let api = PostPlayFixtureAPI(), model = try await ready(api)
        defer { retireHeld(api, model: model) }
        let oldRow = try XCTUnwrap(model.suggestions.first)
        api.holdDetails = true
        let oldLookup = Task { try await model.preparePlay(oldRow) }
        defer { oldLookup.cancel() }
        await until { api.pendingDetails[0] != nil }

        model.load()
        await until { !model.loading }
        let currentRow = try XCTUnwrap(model.suggestions.first)
        XCTAssertFalse(currentRow === oldRow)
        var replacementReturned = false
        let replacement = Task {
            defer { replacementReturned = true }
            return try await model.preparePlay(currentRow)
        }
        defer { replacement.cancel() }
        await until { api.pendingDetails[1] != nil }
        XCTAssertNil(model.details(currentRow))
        try XCTUnwrap(api.pendingDetails.removeValue(forKey: 0)).resume(returning: bundle(oldRow))
        do {
            _ = try await oldLookup.value
            XCTFail("Reload must reject the original row")
        } catch { XCTAssertTrue(error.isCancellation) }

        XCTAssertFalse(replacementReturned, "The genuine replacement lookup is still held")
        XCTAssertNotNil(api.pendingDetails[1])
        XCTAssertNil(model.details(currentRow), "Old lookup cleanup must not release its replacement's slot")
        try XCTUnwrap(api.pendingDetails.removeValue(forKey: 1)).resume(returning: bundle(currentRow))
        let next = try await replacement.value
        XCTAssertTrue(replacementReturned)
        XCTAssertEqual(next.title.titleID, currentRow.title.id)
        XCTAssertNotNil(model.details(currentRow))
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("details:") }.count, 2)
        XCTAssertTrue(api.pendingDetails.isEmpty)
    }
}
