import Foundation

final class CandidateTracker {
    struct ImpulseWindow {
        let samples: [AccelSample]
        let peakIndex: Int
        let baseline: Double
    }

    var onImpulse: ((ImpulseWindow) -> Void)?

    private let maxCollectSamples: Int = 30
    private let quietRatio: Double = 0.3
    private let quietRunToEnd: Int = 5
    private let preBufferSize: Int = 10

    private enum State { case idle, collecting }
    private var state: State = .idle

    private var preBuffer: [AccelSample] = []
    private var collected: [AccelSample] = []
    private var peakIndex: Int = 0
    private var peakDeviation: Double = 0
    private var baselineAtStart: Double = 0
    private var quietRun: Int = 0

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
                state = .idle
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
        let window = ImpulseWindow(samples: all, peakIndex: peakIndex, baseline: baselineAtStart)
        onImpulse?(window)
        preBuffer = clearPreBuffer ? [] : Array(all.suffix(preBufferSize))
        collected = []
    }
}
