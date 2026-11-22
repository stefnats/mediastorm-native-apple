import SwiftUI

@MainActor
struct EpisodeAdvancePanel: View {
    @ObservedObject var model: EpisodeAdvanceController
    let close: () -> Void
    private enum Focus: Hashable { case cancel, close }
    @FocusState private var focused: Focus?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.next?.displayTitle ?? "Next episode").font(.headline)
            if let seconds = model.seconds { Text(model.paused ? "Countdown paused: \(seconds)s" : "Starting in \(seconds)s") }
            if model.cancelled { Text("Autoplay cancelled for this episode.") }
            if let error = model.settingsError {
                Text(error).font(.footnote)
                Button("Reload profile choice") { model.loadSettings() }
            }
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
        }
        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .onAppear { focused = model.seconds == nil ? .close : .cancel }
#if os(tvOS)
        .onExitCommand { model.cancelCountdown() }
#endif
    }
    @ViewBuilder private var actions: some View {
        Button("Start now") { model.startNow() }
        if model.seconds != nil {
            Button(model.paused ? "Resume countdown" : "Pause countdown") { model.pauseCountdown() }
            Button("Cancel autoplay") { model.cancelCountdown() }.focused($focused, equals: .cancel)
        }
        Button("Close player", action: close).focused($focused, equals: .close)
    }
}

/// An exact next request survives a failed resolve. No following episode is derived
/// here; each retry is a separate, explicit claim of this same request.
struct EpisodeTransitionTicket: Identifiable {
    let id = UUID()
    let request: PlaybackRequest
    let context: SourceActionContext
}
struct EpisodeAdvanceFailure: Identifiable {
    let ticket: EpisodeTransitionTicket
    let message: String
    let denied: Bool
    var id: UUID { ticket.id }
    var request: PlaybackRequest { ticket.request }
    var context: SourceActionContext { ticket.context }
}

@MainActor
final class EpisodeTransitionOwnership {
    private let contextCurrent: (SourceActionContext) -> Bool
    private(set) var ticket: EpisodeTransitionTicket?
    private(set) var failure: EpisodeAdvanceFailure?
    private var resolveID: UUID?
    init(current: @escaping (SourceActionContext) -> Bool) { contextCurrent = current }
    func prepare(_ request: PlaybackRequest, context: SourceActionContext) -> EpisodeTransitionTicket? {
        guard contextCurrent(context), request.isEpisode, !request.fileOnlyPlayback else { return nil }
        let next = EpisodeTransitionTicket(request: request, context: context)
        ticket = next; failure = nil; resolveID = nil; return next
    }
    func current(_ value: EpisodeTransitionTicket) -> Bool { ticket?.id == value.id && contextCurrent(value.context) }
    func bind(_ value: EpisodeTransitionTicket, resolve: UUID) -> Bool {
        guard current(value), failure == nil else { return false }; resolveID = resolve; return true
    }
    func current(_ value: EpisodeTransitionTicket, resolve: UUID) -> Bool { current(value) && resolveID == resolve }
    func failed(_ value: EpisodeTransitionTicket, resolve: UUID? = nil, error: Error) -> EpisodeAdvanceFailure? {
        guard current(value), !error.isCancellation, resolve == nil || resolveID == resolve else { return nil }
        let denied = [401, 403].contains((error as? APIError)?.statusCode ?? 0)
        let result = EpisodeAdvanceFailure(ticket: value, message: error.localizedDescription, denied: denied)
        failure = result; return result
    }
    func canRetry(_ value: EpisodeAdvanceFailure) -> Bool {
        current(value.ticket) && failure?.id == value.id && !value.denied
    }
    func retry(_ value: EpisodeAdvanceFailure) -> EpisodeTransitionTicket? {
        guard canRetry(value) else { return nil }; return prepare(value.request, context: value.context)
    }
    func dismiss(_ value: EpisodeAdvanceFailure) { if failure?.id == value.id { retire() } }
    func succeeded(_ value: EpisodeTransitionTicket, resolve: UUID) {
        if current(value, resolve: resolve) { retire() }
    }
    func retire() { ticket = nil; failure = nil; resolveID = nil }
}

@MainActor
struct EpisodeAdvanceRetryScene: View {
    let failure: EpisodeAdvanceFailure
    let current: () -> Bool
    let retry: () -> Void
    let close: () -> Void
    @State private var details = false
    @FocusState private var closeFocused: Bool
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("The next episode could not start").font(.title2)
                Text(failure.request.displayTitle).font(.headline)
                Text(failure.message).font(.callout)
                Text("Retry keeps this episode selected.").font(.footnote)
                HStack {
                    Button("Retry same episode", action: retry).disabled(failure.denied || !current())
                    Button("Details") { if current() { details = true } }.disabled(failure.denied || !current())
                    Button("Close", action: close).focused($closeFocused)
                }
            }.padding(32)
            .navigationDestination(isPresented: $details) {
                if current(), !failure.denied {
#if os(iOS)
                    MobileDetailsView(target: failure.request.title, automaticallyPrewarm: false)
#else
                    DetailsView(target: failure.request.title, automaticallyPrewarm: false)
#endif
                } else { Text("The original playback changed. Close this view.") }
            }
            .onAppear { closeFocused = true }
#if os(tvOS)
            .onExitCommand(perform: close)
#endif
        }
    }
}
