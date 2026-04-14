import Foundation

// Detects a double-knock pattern from a stream of AccelSamples.
//
// Algorithm:
//   1. Maintain a short rolling baseline of magnitude (last ~0.5s of samples)
//   2. A "knock" = single sample where deviation from baseline > threshold
//   3. "Double knock" = two knocks separated by 80–450 ms
//   4. 1 s cooldown after a successful double knock

final class KnockDetector {

    // MARK: Tuning (public for future Settings support)

    /// Deviation above baseline that registers as a knock (in g).
    var threshold: Double = 0.10

    // MARK: Private constants

    private let minGap:  TimeInterval = 0.08
    private let maxGap:  TimeInterval = 0.45
    private let cooldown: TimeInterval = 1.0

    /// Number of samples for the rolling baseline window (~0.5 s at 100 Hz)
    private let baselineWindowSize = 50

    // MARK: State

    private let onDoubleTap: () -> Void
    private var baselineBuffer: [Double] = []
    private var baseline: Double = 1.0       // start at 1 g (gravity)

    private var inKnock = false              // true while magnitude is above threshold
    private var firstKnockTime: TimeInterval = 0
    private var lastTriggerTime: TimeInterval = 0

    // MARK: Init

    init(onDoubleTap: @escaping () -> Void) {
        self.onDoubleTap = onDoubleTap
    }

    // MARK: Feed

    /// Call this from AccelerometerReader.onSample (already on main thread).
    func feed(_ sample: AccelSample) {
        updateBaseline(sample.magnitude)

        let deviation = sample.magnitude - baseline
        let now = ProcessInfo.processInfo.systemUptime

        if deviation > threshold {
            guard !inKnock else { return }     // already inside this spike
            inKnock = true

            guard now - lastTriggerTime > cooldown else { return }

            let gap = now - firstKnockTime
            if firstKnockTime > 0 && gap >= minGap && gap <= maxGap {
                // ✅ Double knock!
                print("[Knock] ✅ DOUBLE KNOCK — gap=\(String(format:"%.3f", gap))s deviation=\(String(format:"%.3f", deviation))g")
                lastTriggerTime = now
                firstKnockTime  = 0
                onDoubleTap()
            } else {
                print("[Knock] 1st knock — deviation=\(String(format:"%.3f", deviation))g baseline=\(String(format:"%.3f", baseline))g")
                firstKnockTime = now
            }
        } else {
            inKnock = false
        }
    }

    // MARK: Baseline

    private func updateBaseline(_ magnitude: Double) {
        baselineBuffer.append(magnitude)
        if baselineBuffer.count > baselineWindowSize {
            baselineBuffer.removeFirst()
        }
        // Use median to avoid knock spikes polluting the baseline
        let sorted = baselineBuffer.sorted()
        baseline = sorted[sorted.count / 2]
    }
}
