import Foundation

/// One ordinary VOD episode transition. All elapsed time is supplied by the
/// consuming monotonic clock; position/duration are actual engine seconds.
struct EpisodeAdvancePolicy {
    let hasTarget: Bool
    var autoplay: Bool?
    var skipCredits = false
    private(set) var mediaEnded = false
    private(set) var cancelled = false
    private(set) var claimed = false
    private(set) var closed = false
    private(set) var failed = false
    private(set) var countdownPaused = false
    private var atCredits = false
    private var playing = false
    private var blocked = false
    private var remainingMS: Double?
    private var previous: Duration?
    init(hasTarget: Bool) { self.hasTarget = hasTarget }
    var seconds: Int? { remainingMS.map { Int(ceil(max(0, $0) / 1000)) } }
    var visible: Bool { hasTarget && !closed && !claimed && !failed && (mediaEnded || seconds != nil) }
    static func genuineEnd(position: Double, duration: Double, failed: Bool) -> Bool {
        !failed && position.isFinite && duration.isFinite && duration > 0 && position > 0 && position >= max(0, duration - 2)
    }
    mutating func observe(credits: Bool, playing: Bool, position: Double, duration: Double, failed: Bool) {
        guard !closed else { return }
        if failed { self.failed = true; remainingMS = nil; previous = nil }
        if atCredits && !credits && !mediaEnded { blocked = true; remainingMS = nil; previous = nil }
        atCredits = credits
        if self.playing != playing { previous = nil }; self.playing = playing
        if mediaEnded && duration > 0 && !Self.genuineEnd(position: position, duration: duration, failed: failed) {
            mediaEnded = false; blocked = true; remainingMS = nil; previous = nil
        }
    }
    @discardableResult
    mutating func ended(position: Double, duration: Double, failed: Bool) -> Bool {
        guard hasTarget, !closed, !claimed, !self.failed, Self.genuineEnd(position: position, duration: duration, failed: failed) else { return false }
        mediaEnded = true
        if let remainingMS { self.remainingMS = min(remainingMS, 5000) }
        return true
    }
    mutating func tick(now: Duration) -> Bool {
        guard hasTarget, !closed, !claimed, !failed else { return false }
        let eligible = autoplay == true && !cancelled && !blocked && (mediaEnded || atCredits && skipCredits)
        guard eligible else { remainingMS = nil; previous = nil; return false }
        if remainingMS == nil { remainingMS = mediaEnded ? 5000 : 7000; previous = now; return false }
        guard !countdownPaused, mediaEnded || playing else { previous = nil; return false }
        guard let before = previous else { previous = now; return false }
        let delta = now - before
        let milliseconds = Double(delta.components.seconds) * 1000 + Double(delta.components.attoseconds) / 1e15
        remainingMS = max(0, remainingMS! - max(0, milliseconds)); previous = now
        return remainingMS == 0 ? claim() : false
    }
    mutating func suspendClock() { previous = nil }
    mutating func togglePause() { guard !closed, !claimed else { return }; countdownPaused.toggle(); previous = nil }
    mutating func cancel() { cancelled = true; remainingMS = nil; previous = nil }
    mutating func claim() -> Bool {
        guard hasTarget, !closed, !claimed, !failed else { return false }
        claimed = true; remainingMS = nil; previous = nil; return true
    }
    mutating func close() { closed = true; remainingMS = nil; previous = nil }
}
