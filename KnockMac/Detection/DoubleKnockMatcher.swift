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
            if gap >= minGap && gap <= maxGap && shapeSimilar(prev, event) {
                onDouble?(gap, event.peak)
                lastEvent = nil
                return
            }
        }
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
