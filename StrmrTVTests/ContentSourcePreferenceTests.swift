import XCTest
@testable import StrmrTV

final class ContentSourcePreferenceTests: XCTestCase {
    func testSourceOnlyUpdateCarriesExplicitTrueFalseAndNull() throws {
        let values: [Bool?] = [true, false, nil]
        for value in values {
            let body = ContentLocalPreference.updateBody(value, contentID: "tmdb:tv:5", contentType: "series")
            XCTAssertEqual(Set(body.keys), Set(["contentId", "contentType", "preferLocalFiles"]))
            let raw = try JSONSerialization.data(withJSONObject: body)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            if let value { XCTAssertEqual(decoded["preferLocalFiles"] as? Bool, value) }
            else { XCTAssertTrue(decoded["preferLocalFiles"] is NSNull) }
            XCTAssertNil(decoded["audioLanguage"])
            XCTAssertNil(decoded["subtitleMode"])
        }
    }

    func testCapabilityIsExplicitAndNilPreferenceMeansInherit() throws {
        let decoder = JSONDecoder()
        let modern = try decoder.decode(ContentLocalPreference.self, from: Data(#"{"localSourcePreferenceSupported":true}"#.utf8))
        XCTAssertTrue(modern.supported)
        XCTAssertNil(modern.preferLocalFiles)
        let old = try decoder.decode(ContentLocalPreference.self, from: Data(#"{"contentId":"tmdb:tv:5","preferLocalFiles":true}"#.utf8))
        XCTAssertFalse(old.supported)
        XCTAssertThrowsError(try decoder.decode(ContentLocalPreference.self,
            from: Data(#"{"localSourcePreferenceSupported":"true"}"#.utf8)))
    }

    func testOriginalRequestKeepsProxyPrefixAndOwnProfile() throws {
        let context = SourceActionContext(baseURL: URL(string: "https://example.invalid/proxy/")!,
            profileID: "own/profile", clientID: "client", sessionToken: "synthetic-session", unlock: "synthetic-unlock")
        let request = try context.request("POST", path: "/api/playback/prequeue/one/report", body: ["sourceVersion":"v"])
        XCTAssertEqual(request.url?.path, "/proxy/api/playback/prequeue/one/report")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "own/profile")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-ID"), "client")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Unlock"), "synthetic-unlock")
    }

    func testContextChangesCannotCompareAsSameOriginalIntent() {
        let url = URL(string: "https://example.invalid")!
        let original = SourceActionContext(baseURL: url, profileID: "one", clientID: "c", sessionToken: "a")
        XCTAssertNotEqual(original, SourceActionContext(baseURL: url, profileID: "two", clientID: "c", sessionToken: "a"))
        XCTAssertNotEqual(original, SourceActionContext(baseURL: url, profileID: "one", clientID: "c", sessionToken: "b"))
        XCTAssertNotEqual(original, SourceActionContext(baseURL: url, profileID: "one", clientID: "other", sessionToken: "a"))
        XCTAssertNotEqual(original, SourceActionContext(baseURL: URL(string: "https://other.invalid")!, profileID: "one", clientID: "c", sessionToken: "a"))
    }
}
