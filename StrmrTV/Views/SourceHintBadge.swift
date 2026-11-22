import SwiftUI

/// Passive annotation only. Rendering never creates a demand subscription.
struct SourceHintBadge: View {
    let value: SourceAvailability?
    var inLibrary = false
    var body: some View {
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

extension View {
    func sourceHintDimming(_ value: SourceAvailability?, inLibrary: Bool = false) -> some View {
        modifier(SourceHintDimming(value:value,inLibrary:inLibrary))
    }
}
private struct SourceHintDimming: ViewModifier {
    let value: SourceAvailability?
    let inLibrary: Bool
    func body(content: Content) -> some View {
        if let value {
            TimelineView(.periodic(from:.now,by:1)) { tick in
                content.opacity(value.presentation(at:tick.date,inLibrary:inLibrary).dimArtwork ? 0.5 : 1)
            }
        } else { content }
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
