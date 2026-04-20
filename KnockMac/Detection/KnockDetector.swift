import Foundation

// Minimal v3 detector. Replaces the v2 stack (AdaptiveBaseline + CandidateTracker
// + ShapeAnalyzer + DoubleKnockMatcher) which produced too many false rejects:
// preBuffer ringing inflated `attack`, sigma drifted on rapid taps, and the
// matcher's shape-similarity check dropped visually-identical knocks.
//
// This detector uses median + MAD (median absolute deviation) for the baseline
// and threshold. Both statistics are robust to impulse outliers, so the threshold
// stays stable while the user taps — no freeze/unfreeze games. Detection is one
// per-sample threshold check + a per-impulse refractory period. Pairing is purely
// gap-based, no shape filter. Typing is rejected by InputActivityGate +
// absoluteFloor.
final class KnockDetector {
    // Public API preserved for KnockController and OnboardingView call sites.
    var onKnock: (() -> Void)?
    var onSingleKnock: ((Double) -> Void)?
    var onDoubleKnockWithGap: ((Double, Double) -> Void)?
    var singleKnockOnly: Bool = false
    var cooldown: TimeInterval = 0.15

    // Three tunables — only these matter.
    private var absoluteFloor: Double = 0.040   // g; never fires below this
    private let k: Double = 6.0                 // MAD multiplier
    private let refractory: TimeInterval = 0.08 // per-impulse lockout
    private let minGap: TimeInterval = 0.08
    private let maxGap: TimeInterval = 0.9

    private let gate = InputActivityGate(suppressionWindow: 0.5)

    // 200-sample ring of magnitudes. Median + MAD recomputed each sample.
    // 200 × ~10ms = 2s of context — long enough to be stable, short enough to
    // adapt to slow drift (laptop being moved, posture change).
    private var ring: [Double] = []
    private let ringCap = 200

    private var lastImpulseTime: TimeInterval = 0
    private var lastPairStart: TimeInterval = 0
    private var lastDoubleTriggerTime: TimeInterval = 0
    private var lastStatusLog: TimeInterval = 0

    init() {
        print("[Detector] v3 initialized — floor=\(absoluteFloor)g k=\(k)·MAD refractory=\(refractory)s gap=[\(minGap),\(maxGap)]s cooldown=\(cooldown)s")
    }

    func feed(_ sample: AccelSample) {
        let now = ProcessInfo.processInfo.systemUptime
        ring.append(sample.magnitude)
        if ring.count > ringCap { ring.removeFirst() }
        guard ring.count >= 30 else { return }

        if gate.shouldSuppress() { return }

        let sorted = ring.sorted()
        let baseline = sorted[sorted.count / 2]
        let mad = medianAbsDev(sorted: sorted, center: baseline)
        let dev = abs(sample.magnitude - baseline)
        let threshold = max(absoluteFloor, k * mad)

        if now - lastStatusLog > 5.0 {
            lastStatusLog = now
            print(String(format: "[Detector] status baseline=%.3fg MAD=%.4f thr=%.3fg", baseline, mad, threshold))
        }

        guard dev > threshold else { return }
        guard now - lastImpulseTime > refractory else { return }
        lastImpulseTime = now

        print(String(format: "[Detector] impulse peak=%.3fg thr=%.3fg", dev, threshold))

        if singleKnockOnly {
            onSingleKnock?(dev)
            return
        }

        if lastPairStart > 0 {
            let gap = now - lastPairStart
            if gap >= minGap && gap <= maxGap {
                guard now - lastDoubleTriggerTime > cooldown else {
                    print(String(format: "[Detector] DOUBLE suppressed by cooldown %.3fs < %.2fs", now - lastDoubleTriggerTime, cooldown))
                    lastPairStart = 0
                    return
                }
                lastDoubleTriggerTime = now
                lastPairStart = 0
                print(String(format: "[Detector] 🎯 DOUBLE gap=%.3fs peak=%.3fg", gap, dev))
                onDoubleKnockWithGap?(gap, dev)
                onKnock?()
                return
            }
            // Gap out of range — current impulse becomes new "1st".
        }
        print(String(format: "[Detector] 1st stored peak=%.3fg", dev))
        lastPairStart = now
    }

    func reloadSettings() {
        let saved = UserDefaults.standard.double(forKey: "knockThreshold")
        if saved > 0 {
            absoluteFloor = saved
            print(String(format: "[Detector] absoluteFloor reloaded → %.3fg", absoluteFloor))
        }
    }

    func setCalibrationMode(threshold: Double) {
        absoluteFloor = threshold
    }

    private func medianAbsDev(sorted: [Double], center: Double) -> Double {
        let devs = sorted.map { abs($0 - center) }.sorted()
        let m = devs[devs.count / 2]
        // 1.4826 is the constant that makes MAD a consistent estimator of σ
        // under a normal distribution. Floor at 0.002 to prevent divide-by-zero
        // on perfectly-quiet signals.
        return max(0.002, m * 1.4826)
    }
}
