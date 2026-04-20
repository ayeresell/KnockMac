import Foundation

final class ShapeAnalyzer {
    enum Classification {
        case accept(peak: Double)
        case reject(reason: String)
    }

    let maxAttackSamples: Int
    let minDecaySamples: Int
    let decayFraction: Double
    let minZDominance: Double
    let maxPreQuietDeviation: Double
    let minPeakDeviation: Double

    init(maxAttackSamples: Int = 4,
         minDecaySamples: Int = 2,
         decayFraction: Double = 0.5,
         minZDominance: Double = 1.3,
         maxPreQuietDeviation: Double = 0.025,
         minPeakDeviation: Double = 0.0) {
        self.maxAttackSamples = maxAttackSamples
        self.minDecaySamples = minDecaySamples
        self.decayFraction = decayFraction
        self.minZDominance = minZDominance
        self.maxPreQuietDeviation = maxPreQuietDeviation
        self.minPeakDeviation = minPeakDeviation
    }

    func classify(_ w: CandidateTracker.ImpulseWindow) -> Classification {
        let samples = w.samples
        guard w.peakIndex < samples.count else {
            return .reject(reason: "invalid_peak_index")
        }
        let peakSample = samples[w.peakIndex]
        let peakDeviation = abs(peakSample.magnitude - w.baseline)

        // 0. Minimum peak check — filters out chassis echoes from earlier impacts.
        if peakDeviation < minPeakDeviation {
            return .reject(reason: "peak_too_weak=\(String(format: "%.3f", peakDeviation))g")
        }

        // 1. Find impulse start: first sample where dev > maxPreQuietDeviation.
        var impulseStart = 0
        for (i, s) in samples.enumerated() {
            if abs(s.magnitude - w.baseline) > maxPreQuietDeviation {
                impulseStart = i
                break
            }
        }

        // 2. Pre-quiet check.
        if impulseStart > 0 {
            let preSamples = samples.prefix(impulseStart)
            let avgPreDev = preSamples.map { abs($0.magnitude - w.baseline) }
                .reduce(0, +) / Double(preSamples.count)
            if avgPreDev > maxPreQuietDeviation {
                return .reject(reason: "pre_noisy avg_dev=\(String(format: "%.3f", avgPreDev))")
            }
        } else {
            return .reject(reason: "no_pre_buffer")
        }

        // 3. Attack check.
        let attackSamples = w.peakIndex - impulseStart
        if attackSamples > maxAttackSamples {
            return .reject(reason: "slow_attack samples=\(attackSamples)")
        }
        if attackSamples < 0 {
            return .reject(reason: "peak_before_start")
        }

        // 4. Decay check.
        let decayWindow = min(samples.count, w.peakIndex + 2 * maxAttackSamples + 1)
        var decayed = false
        var decaySamples = 0
        for i in (w.peakIndex + 1)..<decayWindow {
            decaySamples = i - w.peakIndex
            let dev = abs(samples[i].magnitude - w.baseline)
            if dev < decayFraction * peakDeviation && decaySamples >= minDecaySamples {
                decayed = true
                break
            }
        }
        if !decayed {
            return .reject(reason: "no_decay after=\(decaySamples)")
        }

        // 5. Z-dominance at peak.
        guard w.peakIndex > 0 else {
            return .reject(reason: "no_prev_sample")
        }
        let prev = samples[w.peakIndex - 1]
        let dz = abs(peakSample.z - prev.z)
        let dx = abs(peakSample.x - prev.x)
        let dy = abs(peakSample.y - prev.y)
        let maxLateral = max(dx, dy, 0.0001)
        if dz < minZDominance * maxLateral {
            return .reject(reason: "z_weak dz/xy=\(String(format: "%.2f", dz / maxLateral))")
        }

        return .accept(peak: peakDeviation)
    }
}
