import SwiftUI

/// The form only uses a server-issued sourceVersion and its actual track list.
/// It never posts a guessed release URL, global block or device language as the
/// requested language. Report and alternative preparation are explicit actions.
struct ReleaseReportView: View {
    @ObservedObject var model: ReleaseReportModel
    let position: Double
    let onPlay: (ReleaseReportModel.Transfer, ReleaseAlternativeStart) -> Void
    let onClose: () -> Void
    @State private var reason = ReleaseReportReason.fileProblem
    @State private var audioTrack: Int?
    @State private var alternativeStart = ReleaseAlternativeStart.current
    @State private var resetHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Report / Change Source").font(.title2)
                if let options = model.options {
                    Text(options.releaseName).font(.headline)
                    Text("The report applies to this title and selected source. Language and audio-track problems retain their narrower scope.")
                        .font(.caption).foregroundStyle(.secondary)
                    if options.canShare {
                        Text("Your server may share title reports with other profiles. Profile and device problems keep their narrower scope.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Menu {
                        ForEach(ReleaseReportReason.allCases.filter(options.allows)) { item in
                            Button(item.label) { reason = item; resetHistory = false }
                        }
                    } label: { Label(reason.label, systemImage: "exclamationmark.bubble") }
                    .disabled(model.busy || model.savedReportID != nil || model.outcomeUnknown)
                    if reason == .missingLanguage {
                        Text("Requested audio: \(options.audioLanguage)")
                    }
                    if reason == .audioProblem {
                        Menu {
                            ForEach(options.audioTracks ?? [], id: \.index) { track in
                                Button(trackLabel(track)) { audioTrack = track.index }
                            }
                        } label: {
                            Text("Affected audio track: \(audioTrack.map(String.init) ?? "Choose…")")
                        }
                        .disabled(model.busy)
                    }
                    if reason.permitsHistoryReset && options.canResetHistory {
                        Toggle("Reset this movie / episode's history", isOn: $resetHistory).disabled(model.busy)
                        Text("This does not restore a previous progress snapshot and cannot be undone with the report.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.outcomeUnknown && model.savedReportID == nil && model.replacement == nil {
                        Button("Report only") { submit(retry: false) }.disabled(model.busy)
                        Button("Report and prepare an alternative") { submit(retry: true) }.disabled(model.busy)
                        Button("Prepare an alternative without a report") {
                            model.submit(ReleaseReportSubmission(reason: nil, retry: true, resetHistory: false,
                                                                  audioTrackIndex: nil, position: position))
                        }
                    }
                    if model.savedReportID != nil {
                        Button("Undo this report") { model.undoReport() }.disabled(model.busy)
                    }
                    if model.alternativeAvailable {
                        if !model.wrongContent {
                            Picker("Start alternative", selection: $alternativeStart) {
                                ForEach(ReleaseAlternativeStart.allCases) { Text($0.label).tag($0) }
                            }
                        } else { Text("Wrong-content alternatives always start at the beginning.") }
                        Button("Play Alternative") {
                            guard let next = model.takeReplacement() else { return }
                            onPlay(next, alternativeStart)
                        }
                    }
                } else if !model.busy {
                    Text("No reportable prepared source is available. Use Switch Source for manual library files or older servers.")
                }
                if model.cleanupNeedsRetry {
                    Button("Retry alternative cancellation") { model.retryCleanup() }.disabled(model.busy)
                }
                if model.busy { ProgressView() }
                if let message = model.message { Text(message) }
                Button("Close", role: .cancel) { model.close(); onClose() }
            }
            .padding(40)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            if model.options == nil { model.load() }
        }
        .onDisappear { model.close() }
        #if os(tvOS)
        .onExitCommand { model.close(); onClose() }
        #endif
    }

    private func submit(retry: Bool) {
        model.submit(ReleaseReportSubmission(reason: reason, retry: retry, resetHistory: resetHistory,
            audioTrackIndex: audioTrack, position: position))
    }

    private func trackLabel(_ track: ReleaseReportOptions.AudioTrack) -> String {
        ["#\(track.index)", track.language, track.title, track.codec].compactMap { $0 }.joined(separator: " · ")
    }
}
