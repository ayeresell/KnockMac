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
            // Reset after a successful pair so a continuous tap stream doesn't
            // chain knock2→knock3 into a second double. Pairs are strictly
            // 1+2, 3+4, 5+6 — humans naturally pause between intentional
            // double-knock gestures.
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
