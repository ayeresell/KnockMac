import Foundation

struct KnockEvent {
    let time: TimeInterval
    let peak: Double
    let attackSamples: Int
}

final class DoubleKnockMatcher {
    let minGap: TimeInterval
    let maxGap: TimeInterval
    let maxAmpRatio: Double
    let maxAttackRatio: Double

    var onDouble: ((TimeInterval, Double) -> Void)?
    var onSingle: ((Double) -> Void)?
    var singleKnockOnly: Bool = false

    private var lastEvent: KnockEvent?

    init(minGap: TimeInterval = 0.175,
         maxGap: TimeInterval = 0.325,
         maxAmpRatio: Double = 2.5,
         maxAttackRatio: Double = 2.0) {
        self.minGap = minGap
        self.maxGap = maxGap
        self.maxAmpRatio = maxAmpRatio
        self.maxAttackRatio = maxAttackRatio
    }

    /// Cancel a pending 1st-knock if a shape-rejected impulse lands inside
    /// the pair window. That impulse is almost always a bounce/echo or a
    /// weak knock that would have been the 2nd of the pair — leaving it
    /// unacknowledged keeps `lastEvent` stale and drops the following real
    /// knock as "too slow". Cancelling lets the next valid impulse start a
    /// fresh pair. Outside the pair window the rejected impulse is ignored.
    func submitRejected(time: TimeInterval, reason: String) {
        guard let prev = lastEvent else { return }
        let gap = time - prev.time
        guard gap >= minGap && gap <= maxGap else { return }
        print("[Matcher] pending 1st cancelled — shape-rejected impulse inside window (gap=\(String(format: "%.3f", gap))s, reason=\(reason))")
        lastEvent = nil
    }

    func submit(_ event: KnockEvent) {
        if singleKnockOnly {
            onSingle?(event.peak)
            return
        }

        if let prev = lastEvent {
            let gap = event.time - prev.time
            let ampRatio = max(prev.peak, event.peak) / max(min(prev.peak, event.peak), 0.0001)
            if gap < minGap {
                print("[Matcher] 2nd knock too fast gap=\(String(format: "%.3f", gap))s (min=\(minGap)s) — stored as new first")
                lastEvent = event
                return
            }
            if gap > maxGap {
                print("[Matcher] 2nd knock too slow gap=\(String(format: "%.3f", gap))s (max=\(maxGap)s) — stored as new first")
                lastEvent = event
                return
            }
            if !shapeSimilar(prev, event) {
                print("[Matcher] shape mismatch ampRatio=\(String(format: "%.2f", ampRatio)) (max=\(maxAmpRatio)) — stored as new first")
                lastEvent = event
                return
            }
            print("[Matcher] ✓ pair accepted gap=\(String(format: "%.3f", gap))s ampRatio=\(String(format: "%.2f", ampRatio))")
            onDouble?(gap, event.peak)
            lastEvent = nil
            return
        }
        print("[Matcher] 1st knock stored peak=\(String(format: "%.3f", event.peak))g attack=\(event.attackSamples) — waiting for 2nd")
        lastEvent = event
    }

    private func shapeSimilar(_ a: KnockEvent, _ b: KnockEvent) -> Bool {
        let ampRatio = max(a.peak, b.peak) / max(min(a.peak, b.peak), 0.0001)
        let aAttack = max(1, a.attackSamples)
        let bAttack = max(1, b.attackSamples)
        let attackRatio = Double(max(aAttack, bAttack)) / Double(min(aAttack, bAttack))
        return ampRatio <= maxAmpRatio && attackRatio <= maxAttackRatio
    }
}
