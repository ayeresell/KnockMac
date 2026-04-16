import XCTest
@testable import KnockMac

final class AdaptiveBaselineTests: XCTestCase {
    func testBaselineConvergesToInputMean() {
        let b = AdaptiveBaseline(windowSize: 100, k: 6.0)
        for _ in 0..<100 { b.feed(1.000) }
        XCTAssertEqual(b.baseline, 1.000, accuracy: 0.0001)
    }

    func testSigmaReturnsZeroOnConstantSignal() {
        let b = AdaptiveBaseline(windowSize: 100, k: 6.0,
                                 sigmaFloor: 0, sigmaCeiling: 1.0)
        for _ in 0..<100 { b.feed(1.000) }
        XCTAssertEqual(b.sigma, 0.0, accuracy: 0.0001)
    }

    func testSigmaFloorClampsLowValues() {
        let b = AdaptiveBaseline(windowSize: 100, k: 6.0,
                                 sigmaFloor: 0.003, sigmaCeiling: 1.0)
        for _ in 0..<100 { b.feed(1.000) }
        XCTAssertEqual(b.sigma, 0.003, accuracy: 0.0001)
    }

    func testSigmaCeilingClampsHighValues() {
        let b = AdaptiveBaseline(windowSize: 100, k: 6.0,
                                 sigmaFloor: 0, sigmaCeiling: 0.03)
        // Alternating pattern produces large sigma (~0.5).
        for i in 0..<100 { b.feed(i.isMultiple(of: 2) ? 1.0 : 2.0) }
        XCTAssertEqual(b.sigma, 0.03, accuracy: 0.0001)
    }

    func testThresholdRespectsAbsoluteFloor() {
        let b = AdaptiveBaseline(windowSize: 100, k: 6.0,
                                 sigmaFloor: 0, sigmaCeiling: 1.0,
                                 absoluteFloor: 0.025)
        for _ in 0..<100 { b.feed(1.000) }
        // sigma is 0, so k*sigma = 0, but floor keeps us at 0.025.
        XCTAssertEqual(b.thresholdDeviation, 0.025, accuracy: 0.0001)
    }

    func testThresholdScalesWithSigma() {
        let b = AdaptiveBaseline(windowSize: 100, k: 6.0,
                                 sigmaFloor: 0, sigmaCeiling: 1.0,
                                 absoluteFloor: 0)
        for i in 0..<100 { b.feed(1.0 + (i.isMultiple(of: 2) ? 0.01 : -0.01)) }
        // sigma ≈ 0.01, threshold ≈ 6 * 0.01 = 0.06
        XCTAssertEqual(b.thresholdDeviation, 0.06, accuracy: 0.005)
    }

    func testFreezePreventsUpdates() {
        let b = AdaptiveBaseline(windowSize: 100, k: 6.0)
        for _ in 0..<100 { b.feed(1.000) }
        let beforeBaseline = b.baseline
        b.freeze()
        for _ in 0..<50 { b.feed(5.000) }
        XCTAssertEqual(b.baseline, beforeBaseline, accuracy: 0.0001)
    }

    func testUnfreezeResumesUpdates() {
        let b = AdaptiveBaseline(windowSize: 10, k: 6.0)
        for _ in 0..<10 { b.feed(1.000) }
        b.freeze()
        for _ in 0..<10 { b.feed(5.000) }  // ignored while frozen
        b.unfreeze()
        for _ in 0..<10 { b.feed(2.000) }  // fills the ring with 2.0
        XCTAssertEqual(b.baseline, 2.000, accuracy: 0.0001)
    }
}
