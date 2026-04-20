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
    // Minimum allowed signed Y-axis delta at peak. Trackpad taps near the palm rest
    // consistently produce sdy ≤ -0.003g because the impact flexes the chassis in
    // the opposite direction from a knock on the upper body/lid (data-driven).
    let minSignedDy: Double

    init(maxAttackSamples: Int = 4,
         minDecaySamples: Int = 2,
         decayFraction: Double = 0.5,
         minZDominance: Double = 1.3,
         maxPreQuietDeviation: Double = 0.025,
         minPeakDeviation: Double = 0.0,
         minSignedDy: Double = -.infinity) {
        self.maxAttackSamples = maxAttackSamples
        self.minDecaySamples = minDecaySamples
        self.decayFraction = decayFraction
        self.minZDominance = minZDominance
        self.maxPreQuietDeviation = maxPreQuietDeviation
        self.minPeakDeviation = minPeakDeviation
        self.minSignedDy = minSignedDy
    }

    func classify(_ w: CandidateTracker.ImpulseWindow) -> Classification {
        let samples = w.samples
        guard w.peakIndex < samples.count else {
            return .reject(reason: "invalid_peak_index")
        }
        let peakSample = samples[w.peakIndex]
        // Use parabolic-interpolated peak (true between-sample peak) instead
        // of the raw peak sample. Reduces apparent peak variance for repeated
        // knocks of identical strength by 30-50%.
        let peakDeviation = w.refinedPeakDeviation

        // Per-axis signed displacement from rest, averaged over the first few
        // pre-impulse samples. Stabler than sample-to-sample delta for weak taps.
        let nRef = min(5, samples.count)
        let refX = samples.prefix(nRef).map { $0.x }.reduce(0, +) / Double(nRef)
        let refY = samples.prefix(nRef).map { $0.y }.reduce(0, +) / Double(nRef)
        let refZ = samples.prefix(nRef).map { $0.z }.reduce(0, +) / Double(nRef)
        let xOff = peakSample.x - refX
        let yOff = peakSample.y - refY
        let zOff = peakSample.z - refZ
        print("[Shape.diag] peak=\(String(format: "%.3f", peakDeviation))g xOff=\(String(format: "%+.3f", xOff)) yOff=\(String(format: "%+.3f", yOff)) zOff=\(String(format: "%+.3f", zOff))")

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

        // 2. Pre-quiet check. Only enforced when we actually have pre-impulse
        // samples to inspect — impulseStart=0 means the impulse begins at the
        // first sample of the window (e.g. first knock after launch, or right
        // after a hardCap-emitted impulse cleared the preBuffer). In that case
        // we have nothing to compare against and we trust the impulse.
        if impulseStart > 0 {
            let preSamples = samples.prefix(impulseStart)
            let avgPreDev = preSamples.map { abs($0.magnitude - w.baseline) }
                .reduce(0, +) / Double(preSamples.count)
            if avgPreDev > maxPreQuietDeviation {
                return .reject(reason: "pre_noisy avg_dev=\(String(format: "%.3f", avgPreDev))")
            }
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

        // 6. Directional Y-axis check — trackpad-tap discriminator.
        let sdy = peakSample.y - prev.y
        if sdy < minSignedDy {
            return .reject(reason: "trackpad_dir sdy=\(String(format: "%+.3f", sdy))")
        }

        return .accept(peak: peakDeviation)
    }
}
