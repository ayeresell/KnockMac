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
        return CandidateTracker.ImpulseWindow(samples: samples, peakIndex: peakIndex, baseline: baseline)
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
        let w = CandidateTracker.ImpulseWindow(samples: samples, peakIndex: peakIndex, baseline: 1.0)

        if case .accept = a.classify(w) {
            XCTFail("Expected reject (weak Z dominance)")
        }
    }

    func testRejectsByYOffAtCalibratedThreshold() {
        let T: Double = 0.009
        // Synthesized window: canonical Z knock shape (quiet pre, sharp attack,
        // clean decay). Peak Y is displaced by T - 0.005 = 0.004 from the
        // pre-buffer mean (~0), producing yOff = 0.004 which crosses the
        // reject line (yOff < T = 0.009).
        var samples: [AccelSample] = []
        for _ in 0..<5 { samples.append(AccelSample(x: 0, y: 0, z: 1.0)) }
        samples.append(AccelSample(x: 0, y: 0, z: 1.03))
        samples.append(AccelSample(x: 0, y: 0, z: 1.09))
        samples.append(AccelSample(x: 0, y: T - 0.005, z: 1.12))   // peak
        samples.append(AccelSample(x: 0, y: 0, z: 1.05))
        samples.append(AccelSample(x: 0, y: 0, z: 1.02))
        samples.append(AccelSample(x: 0, y: 0, z: 1.005))
        let peakIndex = 7
        let w = CandidateTracker.ImpulseWindow(samples: samples, peakIndex: peakIndex, baseline: 1.0)

        let a = ShapeAnalyzer(
            maxAttackSamples: 20,
            minDecaySamples: 2,
            decayFraction: 0.5,
            minZDominance: 0.0,
            maxPreQuietDeviation: 0.020,
            minPeakDeviation: 0.060,
            minYOff: T
        )
        if case .accept = a.classify(w) {
            XCTFail("Expected reject (location_yoff)")
        }
    }
}
