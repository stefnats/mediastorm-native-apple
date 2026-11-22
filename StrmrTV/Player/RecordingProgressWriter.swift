import Foundation

/// A single acknowledged CAS chain for this actual joined-copy player. No
/// catalogue history, automatic re-claim or retry after an unknown write outcome.
@MainActor
final class RecordingProgressWriter {
    private(set) var acknowledged: RecordingProgressReceipt
    private(set) var accepting = true
    private(set) var failed = false
    private let api: any RecordingProgressAPI
    private let onFailure: () -> Void
    private var pending: Int64?
    private var work: Task<Void, Never>?
    private var closing: Task<Void, Never>?

    init(_ receipt: RecordingProgressReceipt, api: any RecordingProgressAPI = APIClient.shared, onFailure: @escaping () -> Void = {}) {
        acknowledged = receipt; self.api = api; self.onFailure = onFailure
    }
    private func current() -> Bool {
        !failed && acknowledged.original.ready() && api.isCurrent(acknowledged.original.source.context)
    }
    func offer(_ position: Int64) {
        guard accepting, !failed else { return }
        guard current(), (0...acknowledged.identity.durationMs).contains(position) else { return retire() }
        pending = position
        pump()
    }
    func retire() {
        guard !failed else { return }
        failed = true; accepting = false; pending = nil; onFailure()
        // An already admitted request is joined, not mistaken for a rolled-back POST.
    }
    private func save(_ position: Int64) async throws {
        guard current() else { throw RecordingDataError.unavailable }
        let previous = acknowledged
        let command = try RecordingProgressCommand.touch(previous, position: position)
        let next = try await api.writeRecordingProgress(command)
        guard current(), next.original === previous.original, next.adoptable() else { throw RecordingDataError.unavailable }
        acknowledged = next
    }
    private func pump() {
        guard work == nil, accepting, !failed else { return }
        work = Task { [self] in
            do {
                while accepting, !failed, let value = pending {
                    pending = nil
                    try await save(value)
                }
            } catch { retire() }
            work = nil
            if pending != nil, accepting, !failed { pump() }
        }
    }
    func close(finalPosition: Int64?, discard: Bool = false) async {
        if let closing { await closing.value; return }
        accepting = false; pending = nil
        if discard { retire() }
        let admitted = work
        let completion = Task { [self] in
            if let admitted { await admitted.value }
            if !failed, current(), let position = finalPosition, (0...acknowledged.identity.durationMs).contains(position) {
                do { try await save(position) } catch { retire() }
            }
        }
        closing = completion
        await completion.value
    }
}
