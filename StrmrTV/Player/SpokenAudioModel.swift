import SwiftUI

/// A voluntary check of the actual current track. It never reports, blocks,
/// preloads or changes a release, and never treats unknown audio as a mismatch.
@MainActor
final class SpokenAudioModel: ObservableObject {
    struct Selection: Equatable {
        let track: Int
        let position: Double
    }
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var result: SpokenAudioResult?
    private let id: String
    private let context: SourceActionContext
    private let api: any SpokenAudioAPI
    private let selection: () -> Selection?
    private var task: Task<Void, Never>?
    private var closed = false
    private var checkedTrack: Int?

    init(id: String, context: SourceActionContext, api: any SpokenAudioAPI = APIClient.shared,
         selection: @escaping () -> Selection?) {
        self.id = id; self.context = context; self.api = api; self.selection = selection
    }

    func check(_ options: ReleaseReportOptions) {
        guard !closed, !busy, api.isCurrent(context), let original = selection() else { return }
        do { _ = try APIClient.spokenAudioRequest(id, options: options, track: original.track, offset: original.position, context: context) }
        catch { message = error.localizedDescription; return }
        busy = true; result = nil; message = nil; checkedTrack = original.track
        task = Task { [self] in
            defer { busy = false }
            do {
                let checked = try await api.checkSpokenAudio(id, options: options, track: original.track,
                                                           offset: original.position, context: context)
                guard !closed, !Task.isCancelled, api.isCurrent(context), selection()?.track == original.track else { return }
                try checked.validate(options: options, track: original.track)
                result = checked
                switch checked.status {
                case "likely_match": message = String(localized: "The sampled speech probably matches the requested language.")
                case "likely_mismatch": message = String(localized: "The sampled speech may use another language. Review it and choose Report / Change Source if needed.")
                default: message = String(localized: "Spoken language could not be established. Silence, mixed dialogue and missing evidence remain unknown.")
                }
            } catch {
                guard !closed, !Task.isCancelled, api.isCurrent(context), selection()?.track == original.track else { return }
                message = error.localizedDescription
            }
        }
    }
    func refreshCurrentSelection() {
        guard let checkedTrack else { return }
        if !api.isCurrent(context) || selection()?.track != checkedTrack {
            task?.cancel(); result = nil; message = nil; self.checkedTrack = nil
        }
    }
    func close() { closed = true; result = nil; message = nil; task?.cancel() }
    func waitForCompletion() async { await task?.value }
}

struct SpokenAudioCheckView: View {
    @ObservedObject var model: SpokenAudioModel
    let options: ReleaseReportOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Check spoken language of the current audio track") { model.check(options) }.disabled(model.busy)
            Text("Uses two short samples and your requested language. A probable mismatch requires your review; no source is reported or switched automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if model.busy { ProgressView() }
            if let message = model.message { Text(message) }
        }
        .task {
            while !Task.isCancelled {
                model.refreshCurrentSelection()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        .onDisappear { model.close() }
    }
}
