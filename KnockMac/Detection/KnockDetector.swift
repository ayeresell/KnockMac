import Foundation

protocol KnockAlgorithm {
    var name: String { get }
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool
}

struct MagnitudeThresholdAlgorithm: KnockAlgorithm {
    let name = "Magnitude"
    var threshold = 0.06
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool {
        return abs(sample.magnitude - baseline) > threshold
    }
}

struct JerkAlgorithm: KnockAlgorithm {
    let name = "Jerk"
    let jerkThreshold = 0.03
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool {
        guard let last = history.last else { return false }
        return abs(sample.magnitude - last.magnitude) > jerkThreshold
    }
}

struct EnergyAlgorithm: KnockAlgorithm {
    let name = "Energy"
    let energyThreshold = 0.001
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool {
        let recent = history.suffix(3) + [sample]
        guard recent.count >= 3 else { return false }
        let mean = recent.map(\.magnitude).reduce(0, +) / Double(recent.count)
        let variance = recent.map { pow($0.magnitude - mean, 2) }.reduce(0, +) / Double(recent.count)
        return variance > energyThreshold
    }
}

struct ZAxisAlgorithm: KnockAlgorithm {
    let name = "Z-Dominance"
    let zThreshold = 0.03
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool {
        guard let last = history.last else { return false }
        let dz = abs(sample.z - last.z)
        let dx = abs(sample.x - last.x)
        let dy = abs(sample.y - last.y)
        return dz > zThreshold && dz > (dx + dy) * 0.4
    }
}

struct PeakWidthAlgorithm: KnockAlgorithm {
    let name = "Peak Width"
    func analyze(sample: AccelSample, history: [AccelSample], baseline: Double) -> Bool {
        guard history.count >= 4 else { return false }
        let old = history[history.count - 4]
        return abs(old.magnitude - baseline) < 0.05
    }
}

final class KnockDetector {
    var onKnock: (() -> Void)?
    var onSingleKnock: ((Double) -> Void)?
    var onDoubleKnockWithGap: ((Double, Double) -> Void)?
    
    private var algorithms: [KnockAlgorithm] = []
    
    private var history: [AccelSample] = []
    private var baselineBuffer: [Double] = []
    private var baseline: Double = 1.0
    private let baselineWindowSize = 50
    
    private var minGap: TimeInterval = 0.08
    private var maxGap: TimeInterval = 0.45
    private let cooldown: TimeInterval = 1.0
    
    private var inKnock = false
    private var firstKnockTime: TimeInterval = 0
    private var lastTriggerTime: TimeInterval = 0

    init() {
        reloadSettings()
    }

    func reloadSettings() {
        let defaults = UserDefaults.standard
        let savedThresh = defaults.double(forKey: "knockThreshold")
        let thresh = savedThresh > 0 ? savedThresh : 0.06
        
        let savedGap = defaults.double(forKey: "knockMaxGap")
        self.maxGap = savedGap > 0 ? savedGap : 0.45
        
        algorithms = [
            MagnitudeThresholdAlgorithm(threshold: thresh),
            JerkAlgorithm(),
            EnergyAlgorithm(),
            ZAxisAlgorithm(),
            PeakWidthAlgorithm()
        ]
    }

    // For calibration overrides
    func setCalibrationMode(threshold: Double, maxGap: Double) {
        self.maxGap = maxGap
        algorithms = [
            MagnitudeThresholdAlgorithm(threshold: threshold),
            JerkAlgorithm(),
            EnergyAlgorithm(),
            ZAxisAlgorithm(),
            PeakWidthAlgorithm()
        ]
    }

    func feed(_ sample: AccelSample) {
        updateBaseline(sample.magnitude)
        
        let now = ProcessInfo.processInfo.systemUptime
        
        var votes = 0
        var votingAlgos = [String]()
        for algo in algorithms {
            if algo.analyze(sample: sample, history: history, baseline: baseline) {
                votes += 1
                votingAlgos.append(algo.name)
            }
        }
        
        if votes >= 3 {
            guard !inKnock else {
                history.append(sample)
                if history.count > 10 { history.removeFirst() }
                return
            }
            inKnock = true
            
            guard now - lastTriggerTime > cooldown else {
                history.append(sample)
                if history.count > 10 { history.removeFirst() }
                return
            }
            
            let gap = now - firstKnockTime
            let deviation = sample.magnitude - baseline
            
            if firstKnockTime > 0 && gap >= minGap && gap <= maxGap {
                print("[KnockDetector] ✅ DOUBLE KNOCK DETECTED! gap=\(String(format:"%.3f", gap))s deviation=\(String(format:"%.3f", deviation))g (Votes: \(votes)/5 [\(votingAlgos.joined(separator: ", "))])")
                lastTriggerTime = now
                firstKnockTime = 0
                onDoubleKnockWithGap?(gap, abs(deviation))
                onKnock?()
            } else {
                print("[KnockDetector] 1st knock (Votes: \(votes)/5 [\(votingAlgos.joined(separator: ", "))]) deviation=\(String(format:"%.3f", deviation))g")
                firstKnockTime = now
                onSingleKnock?(abs(deviation))
            }
        } else {
            inKnock = false
        }
        
        history.append(sample)
        if history.count > 10 {
            history.removeFirst()
        }
    }
    
    private func updateBaseline(_ magnitude: Double) {
        baselineBuffer.append(magnitude)
        if baselineBuffer.count > baselineWindowSize {
            baselineBuffer.removeFirst()
        }
        // Use median
        let sorted = baselineBuffer.sorted()
        baseline = sorted[sorted.count / 2]
    }
}
