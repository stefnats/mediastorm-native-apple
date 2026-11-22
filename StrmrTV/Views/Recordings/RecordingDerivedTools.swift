import SwiftUI

/// Shared TV/phone controls. Opening details does not prepare or claim playback.
struct RecordingDerivedTools: View {
    @StateObject private var model: RecordingDerivedModel
    let dismissPresented: Bool

    init(recording: Recording, dismissPresented: Bool = false) {
        _model = StateObject(wrappedValue: RecordingDerivedModel(recording: recording, context: APIClient.shared.sourceContext()))
        self.dismissPresented = dismissPresented
    }
    var body: some View {
        if model.source != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Joined recording copy").font(.headline)
                Text("The server measures the joined media timeline. Capture gaps are omitted; captured parts remain available separately.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Read joined-copy status") { model.readStatus() }
                    .accessibilityIdentifier("recording.derived.status")
                Button("Prepare joined copy") { model.readStatus(prepare: true) }
                    .accessibilityIdentifier("recording.derived.prepare")
                if let observation = model.observation {
                    if observation.descriptor.state == "ready", let duration = observation.descriptor.durationMs {
                        Text("Measured media duration: \(Self.time(duration))")
                        if observation.descriptor.sourceIncomplete || observation.descriptor.gapsOmitted {
                            Text("Incomplete capture. The joined timeline omits capture gaps.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(observation.descriptor.partOffsets.indices, id: \.self) { index in
                            let part = observation.descriptor.partOffsets[index]
                            Text("Part \(part.partIndex): \(Self.time(part.startMs))–\(Self.time(part.startMs + part.durationMs))")
                                .font(.caption).accessibilityIdentifier("recording.timeline.\(part.partIndex)")
                        }
                        Button("Read cross-device recording progress") { model.readProgress() }
                            .accessibilityIdentifier("recording.progress.read")
                    } else {
                        Text("No current joined copy. Preparation requires a separate explicit action.").font(.caption)
                    }
                }
                if let snapshot = model.snapshot {
                    Button("Play joined copy from beginning") { model.play(action: "from-start", dismissPresented: dismissPresented) }
                        .accessibilityIdentifier("recording.progress.from-start")
                    if let position = snapshot.positionMs, snapshot.positionState == "matching" {
                        Button("Resume joined copy at \(Self.time(position))") { model.play(action: "resume", dismissPresented: dismissPresented) }
                            .accessibilityIdentifier("recording.progress.resume")
                    }
                    if let position = snapshot.historicalPositionMs, snapshot.historyState == "compatible" {
                        Button("Use compatible previous position \(Self.time(position))") { model.play(action: "resume-history", dismissPresented: dismissPresented) }
                            .accessibilityIdentifier("recording.progress.history")
                    }
                    if snapshot.positionState == "conflict" {
                        Text("The saved position belongs to a different timeline. Choose an explicit current starting point.").font(.caption)
                    }
                }
                if model.busy { ProgressView() }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.red) }
            }
            .disabled(model.busy)
            .onAppear { model.reappear() }
            .onDisappear { model.close() }
        }
    }
    static func time(_ ms: Int64) -> String {
        let seconds = ms / 1000
        return String(format: "%lld:%02lld:%02lld", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}
