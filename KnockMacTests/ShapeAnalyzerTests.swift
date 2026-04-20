import XCTest
@testable import KnockMac

final class ShapeAnalyzerTests: XCTestCase {
    private func window(preQuietDeltas: [Double], impulseDeltas: [Double],
                        baseline: Double = 1.0) -> CandidateTracker.ImpulseWindow {
        var samples: [AccelSample] = []
        for d in preQuietDeltas {
            samples.append(AccelSample(x: 0, y: 0, z: baseline + d))
        }
        for d in impulseDeltas {
            samples.append(AccelSample(x: 0, y: 0, z: baseline + d))
        }
        let peakIndex = samples.enumerated().max(by: {
            abs($0.element.magnitude - baseline) < abs($1.element.magnitude - baseline)
        })!.offset
        let refined = CandidateTracker.parabolicPeak(samples: samples, peakIndex: peakIndex, baseline: baseline)
        return CandidateTracker.ImpulseWindow(samples: samples, peakIndex: peakIndex, baseline: baseline, refinedPeakDeviation: refined)
    }

    func testAcceptsCanonicalKnock() {
        let a = ShapeAnalyzer()
        let w = window(
            preQuietDeltas: [0.001, 0.001, 0.002, 0.001, 0.001],
            impulseDeltas: [0.03, 0.09, 0.12, 0.05, 0.02, 0.005, 0.005]
        )
        if case .reject(let reason) = a.classify(w) {
            XCTFail("Expected accept, got reject: \(reason)")
        }
    }

    func testRejectsSlowAttack() {
        let a = ShapeAnalyzer()
        let w = window(
            preQuietDeltas: [0.001, 0.001, 0.001, 0.001, 0.001],
            impulseDeltas: [0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.10, 0.05, 0.02]
        )
        if case .accept = a.classify(w) {
            XCTFail("Expected reject (slow attack)")
        }
    }

    func testRejectsPlateau() {
        let a = ShapeAnalyzer()
        let w = window(
            preQuietDeltas: [0.001, 0.001, 0.001, 0.001, 0.001],
            impulseDeltas: [0.05, 0.10, 0.09, 0.09, 0.09, 0.09, 0.09, 0.09]
        )
        if case .accept = a.classify(w) {
            XCTFail("Expected reject (no decay)")
        }
    }

    func testRejectsNoisyPreImpulse() {
        let a = ShapeAnalyzer()
        let w = window(
            preQuietDeltas: [0.03, 0.04, 0.05, 0.04, 0.03],
            impulseDeltas: [0.03, 0.09, 0.12, 0.05, 0.02]
        )
        if case .accept = a.classify(w) {
            XCTFail("Expected reject (pre-noisy)")
        }
    }

    func testRejectsWeakZDominance() {
        let a = ShapeAnalyzer()
        var samples: [AccelSample] = []
        for _ in 0..<5 {
            samples.append(AccelSample(x: 0.001, y: 0, z: 1.0))
        }
        samples.append(AccelSample(x: 0.05, y: 0, z: 1.01))
        samples.append(AccelSample(x: 0.12, y: 0, z: 1.02))
        samples.append(AccelSample(x: 0.03, y: 0, z: 1.005))
        samples.append(AccelSample(x: 0.01, y: 0, z: 1.001))
        samples.append(AccelSample(x: 0.005, y: 0, z: 1.001))
        let peakIndex = 6
        let refined = CandidateTracker.parabolicPeak(samples: samples, peakIndex: peakIndex, baseline: 1.0)
        let w = CandidateTracker.ImpulseWindow(samples: samples, peakIndex: peakIndex, baseline: 1.0, refinedPeakDeviation: refined)

        if case .accept = a.classify(w) {
            XCTFail("Expected reject (weak Z dominance)")
        }
    }
}
