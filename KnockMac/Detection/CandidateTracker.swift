import Foundation

final class CandidateTracker {
    struct ImpulseWindow {
        let samples: [AccelSample]
        let peakIndex: Int
        let baseline: Double
        // Parabolic-interpolated peak deviation. The IMU samples at ~140 Hz so
        // the true peak almost never lands exactly on a sample — fitting a
        // parabola to (peak-1, peak, peak+1) recovers the between-sample peak
        // and dramatically reduces apparent peak variance for repeated knocks
        // of the same strength. Falls back to the raw sample value for end-of-
        // window peaks or non-concave triplets.
        let refinedPeakDeviation: Double
    }

    var onImpulse: ((ImpulseWindow) -> Void)?

    private let maxCollectSamples: Int = 30
    private let quietRatio: Double = 0.7
    private let quietRunToEnd: Int = 5
    private let preBufferSize: Int = 10

    private enum State { case idle, collecting, draining }
    private var state: State = .idle

    private var preBuffer: [AccelSample] = []
    private var collected: [AccelSample] = []
    private var peakIndex: Int = 0
    private var peakDeviation: Double = 0
    private var baselineAtStart: Double = 0
    private var quietRun: Int = 0
    private var drainingSamples: Int = 0

    // Hard cap on how long we wait for the post-impulse signal to fall below
    // threshold before forcing a return to .idle. ~140 Hz × 15 ≈ 100 ms.
    // Without this, a continuous tap stream keeps the tracker stuck in
    // .draining and silently swallows every knock until the signal calms.
    private let maxDrainingSamples: Int = 15

    func reset() {
        state = .idle
        collected = []
        peakIndex = 0
        peakDeviation = 0
        quietRun = 0
        drainingSamples = 0
    }

    func feed(_ sample: AccelSample, deviation: Double, threshold: Double, baseline: Double) {
        switch state {
        case .idle:
            if deviation > threshold {
                state = .collecting
                baselineAtStart = baseline
                collected = []
                peakIndex = 0
                peakDeviation = 0
                quietRun = 0
                appendCollected(sample, deviation: deviation)
            } else {
                appendPreBuffer(sample)
            }
        case .draining:
            // Wait for signal to drop below threshold before accepting a new
            // candidate, but cap the wait so a sustained tap stream cannot
            // keep us pinned here indefinitely.
            drainingSamples += 1
            if deviation <= threshold || drainingSamples >= maxDrainingSamples {
                appendPreBuffer(sample)
                state = .idle
                drainingSamples = 0
            }
        case .collecting:
            appendCollected(sample, deviation: deviation)
            let quietCutoff = threshold * quietRatio
            if deviation < quietCutoff {
                quietRun += 1
            } else {
                quietRun = 0
            }
            let hardCap = collected.count >= maxCollectSamples
            if quietRun >= quietRunToEnd || hardCap {
                emit(clearPreBuffer: hardCap)
                state = hardCap ? .draining : .idle
            }
        }
    }

    private func appendPreBuffer(_ sample: AccelSample) {
        preBuffer.append(sample)
        if preBuffer.count > preBufferSize { preBuffer.removeFirst() }
    }

    private func appendCollected(_ sample: AccelSample, deviation: Double) {
        collected.append(sample)
        if deviation > peakDeviation {
            peakDeviation = deviation
            peakIndex = preBuffer.count + collected.count - 1
        }
    }

    private func emit(clearPreBuffer: Bool = false) {
        let all = preBuffer + collected
        let refined = Self.parabolicPeak(samples: all, peakIndex: peakIndex, baseline: baselineAtStart)
        let window = ImpulseWindow(samples: all, peakIndex: peakIndex, baseline: baselineAtStart, refinedPeakDeviation: refined)
        onImpulse?(window)
        preBuffer = clearPreBuffer ? [] : Array(all.suffix(preBufferSize))
        collected = []
    }

    static func parabolicPeak(samples: [AccelSample], peakIndex: Int, baseline: Double) -> Double {
        let center = abs(samples[peakIndex].magnitude - baseline)
        guard peakIndex > 0, peakIndex < samples.count - 1 else { return center }
        let left  = abs(samples[peakIndex - 1].magnitude - baseline)
        let right = abs(samples[peakIndex + 1].magnitude - baseline)
        // Parabola y = px²+qx+r through (-1,left)(0,center)(1,right):
        //   2p = left + right - 2*center      (denom; negative for a true peak)
        //   vertex_y = center - (right-left)² / (8 * (left+right-2*center)/2)
        let denom = left + right - 2 * center
        guard denom < 0 else { return center }
        let dy = right - left
        return center - (dy * dy) / (4 * denom)
    }
}
