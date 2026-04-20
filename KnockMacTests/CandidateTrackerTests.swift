import XCTest
@testable import KnockMac

final class CandidateTrackerTests: XCTestCase {
    /// Helper: create a sample with only Z-axis deviation from 1.0 g (typical stationary baseline).
    private func sample(z: Double) -> AccelSample {
        AccelSample(x: 0, y: 0, z: z)
    }

    func testStaysIdleBelowThreshold() {
        let t = CandidateTracker()
        var emitted: [CandidateTracker.ImpulseWindow] = []
        t.onImpulse = { emitted.append($0) }

        // All samples below threshold.
        for _ in 0..<20 {
            t.feed(sample(z: 1.001), deviation: 0.001, threshold: 0.025, baseline: 1.0)
        }
        XCTAssertTrue(emitted.isEmpty)
    }

    func testEmitsImpulseAfterDecay() {
        let t = CandidateTracker()
        var emitted: [CandidateTracker.ImpulseWindow] = []
        t.onImpulse = { emitted.append($0) }

        // 5 quiet pre-samples.
        for _ in 0..<5 {
            t.feed(sample(z: 1.001), deviation: 0.001, threshold: 0.025, baseline: 1.0)
        }
        // Impulse: fast rise, then decay.
        let impulseDevs: [Double] = [0.05, 0.10, 0.08, 0.04, 0.01, 0.005, 0.005, 0.005, 0.005, 0.005]
        for d in impulseDevs {
            t.feed(sample(z: 1.0 + d), deviation: d, threshold: 0.025, baseline: 1.0)
        }
        XCTAssertEqual(emitted.count, 1)
        XCTAssertGreaterThanOrEqual(emitted[0].samples.count, 5)
        XCTAssertEqual(emitted[0].baseline, 1.0, accuracy: 0.0001)
    }

    func testPeakIndexTracksMaximumDeviation() {
        let t = CandidateTracker()
        var emitted: [CandidateTracker.ImpulseWindow] = []
        t.onImpulse = { emitted.append($0) }

        for _ in 0..<5 {
            t.feed(sample(z: 1.001), deviation: 0.001, threshold: 0.025, baseline: 1.0)
        }
        // Peak at index 2 (deviation 0.12).
        let devs: [Double] = [0.05, 0.08, 0.12, 0.06, 0.02, 0.005, 0.005, 0.005, 0.005, 0.005]
        for d in devs {
            t.feed(sample(z: 1.0 + d), deviation: d, threshold: 0.025, baseline: 1.0)
        }
        XCTAssertEqual(emitted.count, 1)
        let window = emitted[0]
        let peakDeviation = abs(window.samples[window.peakIndex].magnitude - window.baseline)
        XCTAssertEqual(peakDeviation, 0.12, accuracy: 0.005)
    }

    func testHardCapAt30Samples() {
        let t = CandidateTracker()
        var emitted: [CandidateTracker.ImpulseWindow] = []
        t.onImpulse = { emitted.append($0) }

        // Sustained above-threshold signal. With the draining-timeout in
        // place (~100ms cap), a sustained signal will produce multiple emits
        // — one per (collect + drain) cycle. We just verify each emit
        // respects the per-impulse 30-sample collected cap.
        for _ in 0..<5 {
            t.feed(sample(z: 1.001), deviation: 0.001, threshold: 0.025, baseline: 1.0)
        }
        for _ in 0..<100 {
            t.feed(sample(z: 1.05), deviation: 0.05, threshold: 0.025, baseline: 1.0)
        }
        XCTAssertGreaterThanOrEqual(emitted.count, 1)
        for w in emitted {
            XCTAssertLessThanOrEqual(w.samples.count, 40) // 30 collected + up to 10 pre-samples
        }
    }
}
