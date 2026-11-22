import Combine
import Foundation

/// Original detail-screen observation. Every mutation is a separate explicit action.
@MainActor
final class RecordingDerivedModel: ObservableObject {
    let source: RecordingDerivedSource?
    @Published private(set) var observation: RecordingDerivedObservation?
    @Published private(set) var snapshot: RecordingProgressSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let api: any RecordingProgressAPI
    private var operation: Task<Void, Never>?
    private var closed = false

    init(recording: Recording, context: SourceActionContext, api: any RecordingProgressAPI = APIClient.shared) {
        source = try? RecordingDerivedSource(recording, context: context)
        self.api = api
    }
    func close() { closed = true; operation?.cancel(); snapshot = nil }
    func reappear() { if let source, api.isCurrent(source.context) { closed = false } }
    private func current() throws -> RecordingDerivedSource {
        try Task.checkCancellation()
        guard !closed, let source, api.isCurrent(source.context) else { throw RecordingDataError.unavailable }
        return source
    }
    private func validateSource() async throws -> RecordingDerivedSource {
        let source = try current()
        try await api.validateDerivedSource(source)
        _ = try current()
        return source
    }
    func readStatus(prepare: Bool = false) {
        guard !busy, !closed else { return }
        busy = true; message = nil; snapshot = nil
        operation = Task { [self] in
            defer { busy = false; operation = nil }
            do {
                let source = try await validateSource()
                let next = try await api.derived(source, prepare: prepare, previous: observation)
                _ = try current()
                guard next.source == source else { throw RecordingDataError.unavailable }
                observation = next
            } catch {
                observation = nil
                if !closed { message = String(localized: "The joined-copy outcome is unavailable. Read status explicitly before another attempt.") }
            }
        }
    }
    func readProgress() {
        guard !busy, !closed, let original = observation, original.ready() else { return }
        busy = true; message = nil; snapshot = nil
        operation = Task { [self] in
            defer { busy = false; operation = nil }
            do {
                _ = try await validateSource()
                let value = try await api.readRecordingProgress(original, history: true)
                _ = try current()
                guard observation === original, value.original === original, value.adoptable() else { throw RecordingDataError.unavailable }
                snapshot = value
            } catch {
                if !closed { message = String(localized: "Progress is unavailable. Read it again explicitly; playback has not started.") }
            }
        }
    }
    func play(action: String, dismissPresented: Bool) {
        guard !busy, !closed, let snapshot, snapshot.adoptable() else { return }
        busy = true; message = nil
        self.snapshot = nil // A locally consumed choice is not offered for a second POST.
        operation = Task { [self] in
            defer { busy = false; operation = nil }
            do {
                _ = try await validateSource()
                let command = try RecordingProgressCommand.claim(snapshot, action: action)
                let receipt = try await api.writeRecordingProgress(command)
                _ = try current()
                guard receipt.original === snapshot.original, receipt.adoptable() else { throw RecordingDataError.unavailable }
                try RecordingDerivedPlayback.play(receipt, dismissPresented: dismissPresented)
            } catch {
                if !closed { message = String(localized: "Playback was not adopted. Read current progress explicitly before choosing again.") }
            }
        }
    }
}
