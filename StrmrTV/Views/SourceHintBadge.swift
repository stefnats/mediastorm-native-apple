import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var sourceHintOwner: VisibleSourceHints? = nil
    @Entry var sourceHintOrdinal: Int = 0
}

/// Both passive and demand-backed renderers consume the same observed value.
struct SourceHintValue<Content: View>: View {
    let annotation: SourceAvailability?
    var coordinate: VisibleSourceCoordinate?
    @ViewBuilder var content: (SourceAvailability?) -> Content
    @Environment(\.sourceHintOwner) private var owner
    var body: some View {
        if let owner { ObservedSourceHintValue(owner:owner,annotation:annotation,coordinate:coordinate,content:content) }
        else { content(annotation) }
    }
}
private struct ObservedSourceHintValue<Content: View>: View {
    @ObservedObject var owner: VisibleSourceHints
    let annotation: SourceAvailability?
    let coordinate: VisibleSourceCoordinate?
    @ViewBuilder var content: (SourceAvailability?) -> Content
    var body: some View { content(owner.value(coordinate,annotation:annotation)) }
}

/// Passive annotation only. Rendering never creates a demand subscription.
struct SourceHintBadge: View {
    let value: SourceAvailability?
    var inLibrary = false
    var coordinate: VisibleSourceCoordinate?
    var body: some View {
        SourceHintValue(annotation:value,coordinate:coordinate) { value in
        if let value {
            TimelineView(.periodic(from:.now,by:1)) { tick in
                let hint = value.presentation(at:tick.date,inLibrary:inLibrary)
                Text(hint.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal,7).padding(.vertical,4)
                    .background(.black.opacity(0.78),in:RoundedRectangle(cornerRadius:6))
                    .accessibilityLabel(hint.explanation)
                    .accessibilityIdentifier("source-hint.\(String(describing:hint.kind))")
                    .allowsHitTesting(false)
            }
        }
        }
    }
}

extension View {
    func sourceHintDimming(_ value: SourceAvailability?, inLibrary: Bool = false, coordinate: VisibleSourceCoordinate? = nil) -> some View {
        modifier(SourceHintDimming(value:value,inLibrary:inLibrary,coordinate:coordinate))
    }
    func sourceHintScope(active: Bool = true) -> some View { modifier(SourceHintScope(active:active)) }
    func sourceHintVisible(_ coordinate: VisibleSourceCoordinate?, order: Int? = nil) -> some View {
        modifier(SourceHintCell(coordinate:coordinate,order:order))
    }
}
private struct SourceHintDimming: ViewModifier {
    let value: SourceAvailability?
    let inLibrary: Bool
    let coordinate: VisibleSourceCoordinate?
    func body(content: Content) -> some View {
        SourceHintValue(annotation:value,coordinate:coordinate) { value in
        if let value {
            TimelineView(.periodic(from:.now,by:1)) { tick in
                content.opacity(value.presentation(at:tick.date,inLibrary:inLibrary).dimArtwork ? 0.5 : 1)
            }
        } else { content }
        }
    }
}

enum SourceHintAdapters {
    static func hero(_ card: HomeCard?, visible: Bool) -> VisibleSourceCoordinate? { visible ? card.flatMap{title($0)} : nil }
    static func title(_ card: HomeCard) -> VisibleSourceCoordinate? {
        guard card.symbol == nil, !card.logoTile, card.collageURLs.isEmpty, let target = card.target else { return nil }
        let coordinate = SourceTitleCoordinate(target)
        return coordinate.valid ? .title(coordinate) : nil
    }
    static func title(_ title: Title?) -> VisibleSourceCoordinate? {
        guard let title else { return nil }
        let coordinate = SourceTitleCoordinate(DetailsTarget(title))
        return coordinate.valid ? .title(coordinate) : nil
    }
    static func episode(_ episode: Episode, titleID: String?) -> VisibleSourceCoordinate? {
        guard let titleID, let numbering = episode.numbering, !numbering.seriesId.isEmpty else { return nil }
        let coordinate = SourceEpisodeCoordinate(episode)
        return coordinate.valid ? .episode(titleID:titleID,numbering:numbering,value:coordinate) : nil
    }
    /// Display resolves against the owner's actual currently selected series.
    /// Empty title IDs are never valid subscription coordinates.
    static func episodeDisplay(_ episode: Episode) -> VisibleSourceCoordinate? { self.episode(episode,titleID:"") }
}

private struct SourceHintScope: ViewModifier {
    let active: Bool
    @StateObject private var holder = SourceHintScopeOwner()
    func body(content: Content) -> some View {
        content
            .environment(\.sourceHintOwner,holder.owner)
            .background(SourceHintGeometryProbe { rect, visible in
                holder.observe(rect,visible:visible,allowed:active && !AppSession.shared.protectedBrowsingBlocked)
            })
            .onChange(of:active) { _, value in if !value { holder.hide() } }
            .onDisappear { holder.hide() }
    }
}
private struct SourceHintCell: ViewModifier {
    let coordinate: VisibleSourceCoordinate?
    let order: Int?
    @State private var id = UUID()
    @Environment(\.sourceHintOwner) private var owner
    @Environment(\.sourceHintOrdinal) private var ordinal
    func body(content: Content) -> some View {
        if let owner, let coordinate {
            content.background(SourceHintGeometryProbe { rect, visible in
                owner.record(VisibleSourceRecord(id:id,coordinate:coordinate,rect:visible ? rect : .null,order:order ?? ordinal))
            })
            .onChange(of:coordinate) { _, _ in owner.remove(id) }
            .onDisappear { owner.remove(id) }
        } else { content }
    }
}

/// UIKit supplies the actual containing window and enclosing scroll clips.
/// Creating a lazy SwiftUI cell alone is not a visibility witness.
private struct SourceHintGeometryProbe: UIViewRepresentable {
    let changed: (CGRect,Bool) -> Void
    func makeUIView(context: Context) -> SourceHintGeometryView {
        let view = SourceHintGeometryView(); view.changed = changed; return view
    }
    func updateUIView(_ view: SourceHintGeometryView, context: Context) { view.changed = changed; view.sample() }
    static func dismantleUIView(_ view: SourceHintGeometryView, coordinator: ()) { view.stop() }
}
private final class SourceHintGeometryView: UIView {
    var changed: ((CGRect,Bool) -> Void)?
    private var timer: Timer?
    private var sampling = false
    init() { super.init(frame:.zero); isUserInteractionEnabled = false; backgroundColor = .clear }
    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func didMoveToWindow() {
        super.didMoveToWindow(); stop()
        if window != nil {
            sampling = true
            let timer = Timer(timeInterval:0.5,repeats:true) { [weak self] _ in Task { @MainActor in self?.sample() } }
            RunLoop.main.add(timer,forMode:.common); self.timer = timer
        }
        sample()
    }
    override func layoutSubviews() { super.layoutSubviews(); sample() }
    func stop() { sampling = false; timer?.invalidate(); timer = nil }
    func sample() {
        guard sampling else { return }
        guard let window, !window.isHidden, window.windowScene?.activationState == .foregroundActive else { changed?(.null,false); return }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top, isDescendant(of:top.view) else { changed?(.null,false); return }
        var rect = convert(bounds,to:window).intersection(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor, view !== window {
            guard !view.isHidden, view.alpha > 0.01 else { changed?(.null,false); return }
            if view is UIScrollView || view.clipsToBounds { rect = rect.intersection(view.convert(view.bounds,to:window)) }
            ancestor = view.superview
        }
        changed?(rect,!rect.isNull && rect.width > 0 && rect.height > 0)
    }
}

enum SourceHintNavigation {
    static func target(_ original: DetailsTarget, hint: SourceAvailability?, now: Date = .now, inLibrary: Bool = false) -> DetailsTarget {
        var target = original
        target.suppressAutomaticSourcePreparation = original.suppressAutomaticSourcePreparation || hint?.presentation(at:now,inLibrary:inLibrary).dimArtwork == true
        return target
    }
    static func autoplay(primary: Bool, target: DetailsTarget) -> Bool { primary && !target.suppressAutomaticSourcePreparation }
}
