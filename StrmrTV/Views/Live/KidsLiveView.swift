import SwiftUI
import UIKit

/// Same provider-free catalogue on TV and phone. No adult source/action menu.
struct KidsLiveView: View {
    @StateObject private var store = KidsLiveStore()
    @State private var errorMessage: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Child Live TV").font(.title)
                Text("Programme ages are claims from the guide selected by a parent. Playback ends with the selected programme.")
                if store.loading { ProgressView() }
                if let message = store.message { Text(message) }
                ForEach(store.channels) { channel in
                    Button {
                        KidsLivePlayerViewController.present(channel, context: store.context) { errorMessage = $0 }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(channel.name).font(.headline)
                            if let programme = channel.programme {
                                Text(programme.title)
                                Text(programme.claim).font(.callout)
                            } else { Text(channel.programmeReason ?? "No clear current programme age information.") }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(!channel.selectable)
                }
                Button("Refresh programmes") { Task { await store.load() } }
            }.padding(40)
        }
        .task { await store.load() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await store.load() }
        }
        .alert("Programme unavailable", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
