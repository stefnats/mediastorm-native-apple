import SwiftUI

struct EpisodeAutoplayControl: View {
    @StateObject private var model = EpisodeAutoplayModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let enabled = model.enabled {
                Toggle("Next Episode Autoplay", isOn: Binding(get: { enabled }, set: { model.save($0) }))
                    .disabled(model.busy || !model.current)
            } else {
                Button("Reload Next Episode Autoplay") { model.load() }.disabled(model.busy || !model.current)
            }
            Text("Saved for this profile on all devices. Independent of credits skipping.").font(.footnote).foregroundStyle(.secondary)
            if model.busy { ProgressView() }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .task { model.appear() }
        .onDisappear { model.close() }
    }
}
