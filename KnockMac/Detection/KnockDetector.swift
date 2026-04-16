import Foundation

protocol KnockAlgorithm {
    var name: String { get }
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool
}

// MARK: - Algorithms

/// Detects absolute amplitude spike above calibrated threshold.
struct MagnitudeThresholdAlgorithm: KnockAlgorithm {
    let name = "Magnitude"
    var threshold = 0.06
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool {
        abs(sample.magnitude - baseline) > threshold
    }
}

/// Detects rate-of-change spike. Threshold scales with calibrated magnitude threshold
/// so it stays meaningful across the full sensitivity range.
struct JerkAlgorithm: KnockAlgorithm {
    let name = "Jerk"
    let magnitudeThreshold: Double
    var jerkThreshold: Double { max(0.015, magnitudeThreshold * 0.5) }
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool {
        guard let last = history.last else { return false }
        return abs(sample.magnitude - last.magnitude) > jerkThreshold
    }
}

/// Detects energy burst via variance of recent samples.
/// Threshold scales with magnitude threshold (variance ∝ amplitude²).
struct EnergyAlgorithm: KnockAlgorithm {
    let name = "Energy"
    let magnitudeThreshold: Double
    var energyThreshold: Double { max(0.0002, magnitudeThreshold * 0.015) }
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool {
        guard history.count >= 3 else { return false }
        // Inline to avoid array allocations on every sample (called at 100 Hz).
        let m0 = history[history.count - 3].magnitude
        let m1 = history[history.count - 2].magnitude
        let m2 = history[history.count - 1].magnitude
        let m3 = sample.magnitude
        let mean = (m0 + m1 + m2 + m3) * 0.25
        let variance = (pow(m0 - mean, 2) + pow(m1 - mean, 2) + pow(m2 - mean, 2) + pow(m3 - mean, 2)) * 0.25
        return variance > energyThreshold
    }
}

/// Knocks on the laptop body transmit primarily through Z (perpendicular to surface).
/// Compares Z change against each axis individually (not their sum) for stricter filtering.
/// Threshold scales with calibrated magnitude threshold.
struct ZAxisAlgorithm: KnockAlgorithm {
    let name = "Z-Dominance"
    let magnitudeThreshold: Double
    var zThreshold: Double { max(0.015, magnitudeThreshold * 0.4) }
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool {
        guard let last = history.last else { return false }
        let dz = abs(sample.z - last.z)
        let dx = abs(sample.x - last.x)
        let dy = abs(sample.y - last.y)
        // Z must exceed each axis individually — typing distributes across all axes, knocks don't
        return dz > zThreshold && dz > dx * 1.5 && dz > dy * 1.5
    }
}

/// Verifies we're at the start of a fresh impulse, not mid-vibration.
/// Checks that the oldest samples in the 100ms window were near baseline.
/// Replaces PeakWidth which only checked one arbitrary sample index.
struct ImpulseAlgorithm: KnockAlgorithm {
    let name = "Impulse"
    let magnitudeThreshold: Double
    var preQuietThreshold: Double { max(0.025, magnitudeThreshold * 0.8) }
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool {
        guard history.count >= 8 else { return false }
        // Oldest 4 samples (~60–100 ms ago at 100 Hz) should be quiet.
        // Inline to avoid array allocation on every sample (called at 100 Hz).
        let preAvg = (history[0].magnitude + history[1].magnitude + history[2].magnitude + history[3].magnitude) * 0.25
        return abs(preAvg - baseline) < preQuietThreshold
    }
}

// MARK: - Detector

final class KnockDetector {
    var onKnock: (() -> Void)?
    var onSingleKnock: ((Double) -> Void)?
    var onDoubleKnockWithGap: ((Double, Double) -> Void)?
    var singleKnockOnly: Bool = false

    private var algorithms: [KnockAlgorithm] = []

    private var history: [AccelSample] = []
    private var baselineBuffer: [Double] = []
    private var baseline: Double = 1.0
    private let baselineWindowSize = 50

    private let minGap: TimeInterval = 0.20
    private let maxGap: TimeInterval = 0.30
    private let cooldown: TimeInterval = 1.0

    private var inKnock = false
    private var knockEnterTime: TimeInterval = 0
    private let minKnockDuration: TimeInterval = 0.15
    private var firstKnockTime: TimeInterval = 0
    private var lastTriggerTime: TimeInterval = 0
    // Consecutive high-vote counter: filters single-sample noise spikes.
    private var consecutiveHighVotes: Int = 0

    // Deferred callback: triggered at knock onset, fired after knock settles.
    // This ensures the peak is captured even if it arrives after the trigger sample.
    private enum PendingCallback {
        case single
        case double(gap: TimeInterval)
    }
    private var pendingCallback: PendingCallback? = nil
    private var pendingPeakDeviation: Double = 0
    // How many more high-vote samples we still accept for peak tracking.
    // Capped at 5 (~50 ms at 100 Hz) to exclude chassis resonance oscillations
    // that arrive after the primary impulse and would inflate light-tap readings.
    private var peakTrackingSamplesLeft: Int = 0

    init() {
        reloadSettings()
    }

    func reloadSettings() {
        let savedThresh = UserDefaults.standard.double(forKey: "knockThreshold")
        let thresh = savedThresh > 0 ? savedThresh : 0.06
        algorithms = buildAlgorithms(threshold: thresh)
    }

    func setCalibrationMode(threshold: Double) {
        algorithms = buildAlgorithms(threshold: threshold)
    }

    private func buildAlgorithms(threshold: Double) -> [KnockAlgorithm] {
        return [
            MagnitudeThresholdAlgorithm(threshold: threshold),
            JerkAlgorithm(magnitudeThreshold: threshold),
            EnergyAlgorithm(magnitudeThreshold: threshold),
            ZAxisAlgorithm(magnitudeThreshold: threshold),
            ImpulseAlgorithm(magnitudeThreshold: threshold)
        ]
    }

    func feed(_ sample: AccelSample) {
        updateBaseline(sample.magnitude)
        let now = ProcessInfo.processInfo.systemUptime

        defer {
            history.append(sample)
            if history.count > 10 { history.removeFirst() }
        }

        var votes = 0
        var votingAlgos = [String]()
        for algo in algorithms {
            if algo.analyze(sample: sample, history: history, baseline: baseline) {
                votes += 1
                votingAlgos.append(algo.name)
            }
        }

        if votes >= 3 {
            consecutiveHighVotes += 1
            // Track peak until signal starts declining — that's where the true impulse ends
            // and chassis resonance begins. Stop immediately on first drop.
            if pendingCallback != nil && peakTrackingSamplesLeft > 0 {
                let current = abs(sample.magnitude - baseline)
                if current < pendingPeakDeviation {
                    peakTrackingSamplesLeft = 0
                } else {
                    pendingPeakDeviation = current
                    peakTrackingSamplesLeft -= 1
                }
            }
        } else {
            consecutiveHighVotes = 0
            if inKnock && now - knockEnterTime > minKnockDuration {
                inKnock = false
                // Knock has settled — fire callback with true peak
                firePendingCallback()
            }
            return
        }

        // Strong sharp knocks (≥4/5 votes) trigger immediately — their impulse is
        // too brief to guarantee a second high-vote sample. Weaker signals (3/5)
        // require 2 consecutive samples to filter single-sample noise spikes.
        let strongEnough = votes >= 4
        guard consecutiveHighVotes == 2 || (consecutiveHighVotes == 1 && strongEnough) else { return }

        guard !inKnock else { return }
        inKnock = true
        knockEnterTime = now

        guard now - lastTriggerTime > cooldown else { return }

        let gap = now - firstKnockTime
        // Initial peak estimate from backward window; updated sample-by-sample until knock settles.
        let initialPeak = (history.suffix(5) + [sample]).map { abs($0.magnitude - baseline) }.max()
                          ?? abs(sample.magnitude - baseline)

        if !singleKnockOnly && firstKnockTime > 0 && gap >= minGap && gap <= maxGap {
            print("[KnockDetector] ✅ DOUBLE KNOCK triggered gap=\(String(format:"%.3f", gap))s (\(votes)/5 [\(votingAlgos.joined(separator:", "))])")
            lastTriggerTime = now
            firstKnockTime = 0
            pendingCallback = .double(gap: gap)
            pendingPeakDeviation = initialPeak
            peakTrackingSamplesLeft = 5
        } else {
            print("[KnockDetector] 1st knock (\(votes)/5 [\(votingAlgos.joined(separator:", "))]) initial=\(String(format:"%.3f", initialPeak))g")
            if !singleKnockOnly { firstKnockTime = now }
            pendingCallback = .single
            pendingPeakDeviation = initialPeak
            peakTrackingSamplesLeft = 5
        }
    }

    private func firePendingCallback() {
        guard let pending = pendingCallback else { return }
        pendingCallback = nil
        let peak = pendingPeakDeviation
        switch pending {
        case .single:
            print("[KnockDetector] 1st knock settled dev=\(String(format:"%.3f", peak))g")
            onSingleKnock?(peak)
        case .double(let gap):
            print("[KnockDetector] ✅ DOUBLE KNOCK settled gap=\(String(format:"%.3f", gap))s dev=\(String(format:"%.3f", peak))g")
            onDoubleKnockWithGap?(gap, peak)
            onKnock?()
        }
    }

    private func updateBaseline(_ magnitude: Double) {
        baselineBuffer.append(magnitude)
        if baselineBuffer.count > baselineWindowSize {
            baselineBuffer.removeFirst()
        }
        let sorted = baselineBuffer.sorted()
        baseline = sorted[sorted.count / 2]
    }
}
