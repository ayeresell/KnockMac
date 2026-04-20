import Foundation

final class AdaptiveBaseline {
    let windowSize: Int
    let k: Double
    let sigmaFloor: Double
    let sigmaCeiling: Double
    let absoluteFloor: Double

    private var ring: [Double]
    private var writeIndex: Int = 0
    private var count: Int = 0
    private var sum: Double = 0
    private var sumOfSquares: Double = 0
    private var frozen: Bool = false

    init(windowSize: Int = 200,
         k: Double = 6.0,
         sigmaFloor: Double = 0.003,
         sigmaCeiling: Double = 0.03,
         absoluteFloor: Double = 0.025) {
        self.windowSize = windowSize
        self.k = k
        self.sigmaFloor = sigmaFloor
        self.sigmaCeiling = sigmaCeiling
        self.absoluteFloor = absoluteFloor
        self.ring = Array(repeating: 0.0, count: windowSize)
    }

    var baseline: Double {
        count == 0 ? 0 : sum / Double(count)
    }

    var sigma: Double {
        guard count > 1 else { return sigmaFloor }
        let mean = sum / Double(count)
        let variance = max(0, (sumOfSquares / Double(count)) - mean * mean)
        let raw = variance.squareRoot()
        return min(sigmaCeiling, max(sigmaFloor, raw))
    }

    var thresholdDeviation: Double {
        max(absoluteFloor, k * sigma)
    }

    func feed(_ magnitude: Double) {
        guard !frozen else { return }
        if count == windowSize {
            let old = ring[writeIndex]
            sum -= old
            sumOfSquares -= old * old
        } else {
            count += 1
        }
        ring[writeIndex] = magnitude
        sum += magnitude
        sumOfSquares += magnitude * magnitude
        writeIndex = (writeIndex + 1) % windowSize
    }

    func freeze() { frozen = true }
    func unfreeze() { frozen = false }
}
