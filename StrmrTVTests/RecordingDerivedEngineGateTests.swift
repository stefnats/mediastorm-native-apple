import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class RecordingDerivedEngineGateTests: XCTestCase {
    func testActualGatePassesExactServerResumeThroughLoadSeekAndConfirmedStart() async throws {
        let receipt = try RecordingDVRFixture.receipt(position: 12_345), api = RecordingDVRAPI(receipt.original)
        let gate = RecordingDerivedStartGate(receipt, api: api)
        var loaded: Double?, sought: Double?, position = 0.0, playing = false
        try await gate.start(load: { loaded = $0 }, duration: { 60 }, position: { position },
            seek: { sought = $0; position = $0 }, play: { playing = true }, playing: { playing })
        XCTAssertEqual(loaded, 12.345); XCTAssertEqual(sought, 12.345); XCTAssertTrue(gate.started)
        XCTAssertEqual(api.events, ["source", "source"])
    }
    func testHeldLoadCannotAdoptAnExpiredReceipt() async throws {
        let receipt = try RecordingDVRFixture.receipt(position: 7000), api = RecordingDVRAPI(receipt.original)
        var now = ContinuousClock.now, plays = 0, seeks = 0
        let gate = RecordingDerivedStartGate(receipt, api: api, now: { now })
        do {
            try await gate.start(load: { _ in now = receipt.deadline }, duration: { 60 }, position: { 7 },
                seek: { _ in seeks += 1 }, play: { plays += 1 }, playing: { true })
            XCTFail("Expired load was adopted")
        } catch {}
        XCTAssertEqual(plays, 0); XCTAssertEqual(seeks, 0); XCTAssertFalse(gate.started)
    }
    func testMetadataWaitConsumesOnlyOriginalRemainingReceiptDeadline() async throws {
        let receipt = try RecordingDVRFixture.receipt(), api = RecordingDVRAPI(receipt.original)
        var now = ContinuousClock.now, plays = 0, waits = 0
        let gate = RecordingDerivedStartGate(receipt, api: api, now: { now })
        do {
            try await gate.start(load: { _ in }, duration: { 0 }, position: { 0 }, seek: { _ in },
                play: { plays += 1 }, playing: { true }, wait: { waits += 1; now = receipt.deadline })
            XCTFail("Metadata received a new 30-second budget")
        } catch {}
        XCTAssertEqual(waits, 1); XCTAssertEqual(plays, 0)
    }
    func testIncompatibleMeasuredDurationCannotScalePositionOrStartAtZero() async throws {
        for duration in [59.999, 60.00001, Double.nan, Double.infinity] {
            let receipt = try RecordingDVRFixture.receipt(position: 7000), api = RecordingDVRAPI(receipt.original)
            let gate = RecordingDerivedStartGate(receipt, api: api)
            var plays = 0, seeks = 0
            do {
                try await gate.start(load: { position in XCTAssertEqual(position, 7) }, duration: { duration }, position: { 0 },
                    seek: { _ in seeks += 1 }, play: { plays += 1 }, playing: { true })
                XCTFail("Different measured duration was adopted")
            } catch {}
            XCTAssertEqual(plays, 0); XCTAssertEqual(seeks, 0)
        }
    }
    func testRoundedSeekMustActuallyReachAcknowledgedIntegerPosition() async throws {
        let receipt = try RecordingDVRFixture.receipt(position: 7000), api = RecordingDVRAPI(receipt.original)
        var now = ContinuousClock.now, plays = 0, seeks = 0
        let gate = RecordingDerivedStartGate(receipt, api: api, now: { now })
        do {
            try await gate.start(load: { _ in }, duration: { 60 }, position: { 6.5 }, seek: { _ in seeks += 1 },
                play: { plays += 1 }, playing: { true }, wait: { now = receipt.deadline })
            XCTFail("Unreached resume position was treated as successful")
        } catch {}
        XCTAssertEqual(seeks, 1); XCTAssertEqual(plays, 0)
    }
    func testLateProfileChangeAfterSeekCannotTriggerPlay() async throws {
        let receipt = try RecordingDVRFixture.receipt(), api = RecordingDVRAPI(receipt.original), gate = RecordingDerivedStartGate(receipt, api: api)
        var plays = 0
        do {
            try await gate.start(load: { _ in }, duration: { 60 }, position: { 0 },
                seek: { _ in api.context = RecordingDVRFixture.context("replacement") }, play: { plays += 1 }, playing: { true })
            XCTFail("Replacement viewer adopted original start")
        } catch {}
        XCTAssertEqual(plays, 0)
    }
    func testClosedSameContextPlayerCannotActOnMaskedLateLoad() async throws {
        let receipt = try RecordingDVRFixture.receipt(), api = RecordingDVRAPI(receipt.original), gate = RecordingDerivedStartGate(receipt, api: api)
        var plays = 0
        do {
            try await gate.start(load: { _ in gate.close() }, duration: { 60 }, position: { 0 }, seek: { _ in }, play: { plays += 1 }, playing: { true })
            XCTFail("Closed player adopted late load")
        } catch {}
        XCTAssertEqual(plays, 0)
    }
    func testPlayingMustBeConfirmedBeforeReceiptExpires() async throws {
        let receipt = try RecordingDVRFixture.receipt(), api = RecordingDVRAPI(receipt.original)
        var now = ContinuousClock.now, plays = 0
        let gate = RecordingDerivedStartGate(receipt, api: api, now: { now })
        do {
            try await gate.start(load: { _ in }, duration: { 60 }, position: { 0 }, seek: { _ in }, play: { plays += 1 },
                playing: { false }, wait: { now = receipt.deadline })
            XCTFail("Unconfirmed start was adopted")
        } catch {}
        XCTAssertEqual(plays, 1); XCTAssertFalse(gate.started)
    }
    func testSuccessfulStartHasNoRollingThirtySecondStopButRetainsArtifactExpiry() async throws {
        let receipt = try RecordingDVRFixture.receipt(), api = RecordingDVRAPI(receipt.original)
        var now = ContinuousClock.now
        let gate = RecordingDerivedStartGate(receipt, api: api, now: { now })
        try await gate.start(load: { _ in }, duration: { 60 }, position: { 0 }, seek: { _ in }, play: {}, playing: { true })
        now = receipt.deadline.advanced(by: .seconds(31))
        XCTAssertNoThrow(try gate.requireCurrent(adopting: !gate.started))
        XCTAssertThrowsError(try gate.requireCurrent(adopting: true))
        now = try XCTUnwrap(receipt.original.deadline)
        XCTAssertThrowsError(try gate.requireCurrent())
    }
}
