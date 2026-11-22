import SwiftUI

/// Channels as 16:9 cards: logo, what is on now with its progress, and a favorite star.
/// More channels load as the grid nears its end. Menu moves focus up to the category
/// picker (see `LiveContentFocus`).
struct LiveChannelGrid: View {
    let now: Date
    @Binding var request: LiveContentFocus?
    let onExit: () -> Void
    @EnvironmentObject private var store: LiveStore
    @State private var gridWidth: CGFloat = 0
    @FocusState private var focus: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(store.stationSections) { section in
                    if section.stationID != nil {
                        Button { store.toggleStation(section) } label: {
                            Label("\(section.name) · \(section.scope)", systemImage: store.isCollapsed(section) ? "chevron.right" : "chevron.down")
                        }
                        .focused($focus, equals: section.id)
                    }
                    if !store.isCollapsed(section) {
                        CardGrid(items: section.members, cardWidth: LiveChannelCard.width, available: gridWidth, resizable: false,
                                 onNearEnd: {}) { member, width in
                            LiveChannelCard(channel: member.channel, width: width, now: now, focus: $focus)
                        }
                    }
                    Color.clear.frame(height: 1).onAppear { store.stationAppeared(section) }
                }
            }
            .padding(.horizontal, CardGridLayout.inset)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - CardGridLayout.inset * 2 } action: { gridWidth = $0 }

        }
        .liveContentFocus($focus, request: $request, memory: $store.focusMemory,
                          match: { id in store.stationSections.contains { $0.stationID != nil && $0.id == id } || store.displayedChannels.contains { $0.presentationKey == id } ? id : nil },
                          onExit: onExit)
    }
}

struct LiveChannelCard: View {
    static let width: CGFloat = 340

    let channel: LiveChannel
    let width: CGFloat
    let now: Date
    var focus: FocusState<String?>.Binding
    @EnvironmentObject private var store: LiveStore
    @Environment(\.liveChannelPick) private var pick
    @Environment(\.livePlayingChannelID) private var playingID

    private var size: CGSize { CGSize(width: width, height: (width * 9 / 16).rounded()) }

    var body: some View {
        let current = store.current(channel, at: now)
        VStack(alignment: .leading, spacing: 14) {
            Button {
                if let pick { pick.run(channel) } else { LivePlayback.play(channel, program: current) }
            } label: {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                    ChannelLogo(channel: channel, size: CGSize(width: size.width * 0.6, height: size.height * 0.55))
                }
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .bottom) {
                    if let current { ProgressBar(fraction: current.progress(at: now)).padding(14) }
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 10) {
                        if let recording = store.recording(on: channel) { LiveRecordingBadge(recording: recording) }
                        if store.favorites.contains(channel.id) {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                        }
                    }
                    .padding(14)
                }
                .overlay(alignment: .topLeading) {
                    if playingID == channel.id {
                        Image(systemName: "play.fill").font(.caption).foregroundStyle(Color.accentColor).padding(14)
                    } else if store.hidden.contains(channel.id) {
                        Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary).padding(14)
                    }
                }
            }
            .cardLift()
            .focused(focus, equals: channel.presentationKey)
            .contextMenu { LiveChannelMenu(channel: channel) }
            .accessibilityLabel([channel.name, current?.title].compactMap { $0 }.joined(separator: ", "))
            .onAppear { store.needNowNext(channel) }

            CardCaption(title: channel.name, subtitle: [channel.sourceName, current?.title ?? channel.group].compactMap { $0 }.joined(separator: " · "), width: width)
        }
    }
}
