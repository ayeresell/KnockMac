import XCTest
@testable import KnockMac

final class DoubleKnockMatcherTests: XCTestCase {
    func testFiresOnValidPair() {
        let m = DoubleKnockMatcher()
        var doubleGaps: [Double] = []
        m.onDouble = { gap, _ in doubleGaps.append(gap) }

        m.submit(KnockEvent(time: 0.0, peak: 0.10, attackSamples: 3))
        m.submit(KnockEvent(time: 0.25, peak: 0.11, attackSamples: 3))
        XCTAssertEqual(doubleGaps.count, 1)
        XCTAssertEqual(doubleGaps[0], 0.25, accuracy: 0.001)
    }

    func testRejectsTooFast() {
        let m = DoubleKnockMatcher()
        var fired = false
        m.onDouble = { _, _ in fired = true }

        m.submit(KnockEvent(time: 0.0, peak: 0.10, attackSamples: 3))
        m.submit(KnockEvent(time: 0.05, peak: 0.10, attackSamples: 3))
        XCTAssertFalse(fired)
    }

    func testRejectsTooSlow() {
        let m = DoubleKnockMatcher()
        var fired = false
        m.onDouble = { _, _ in fired = true }

        m.submit(KnockEvent(time: 0.0, peak: 0.10, attackSamples: 3))
        m.submit(KnockEvent(time: 0.5, peak: 0.10, attackSamples: 3))
        XCTAssertFalse(fired)
    }

    func testRejectsDissimilarAmplitudes() {
        let m = DoubleKnockMatcher()
        var fired = false
        m.onDouble = { _, _ in fired = true }

        m.submit(KnockEvent(time: 0.0, peak: 0.03, attackSamples: 3))
        m.submit(KnockEvent(time: 0.25, peak: 0.15, attackSamples: 3))
        XCTAssertFalse(fired)
    }

    func testResetsAfterSuccessfulDouble() {
        let m = DoubleKnockMatcher()
        var count = 0
        m.onDouble = { _, _ in count += 1 }

        m.submit(KnockEvent(time: 0.0, peak: 0.10, attackSamples: 3))
        m.submit(KnockEvent(time: 0.25, peak: 0.11, attackSamples: 3))  // fires
        m.submit(KnockEvent(time: 0.40, peak: 0.10, attackSamples: 3))
        XCTAssertEqual(count, 1)
    }

    func testSingleKnockOnlyMode() {
        let m = DoubleKnockMatcher()
        m.singleKnockOnly = true
        var singles: [Double] = []
        var doubles = 0
        m.onSingle = { singles.append($0) }
        m.onDouble = { _, _ in doubles += 1 }

        m.submit(KnockEvent(time: 0.0, peak: 0.10, attackSamples: 3))
        m.submit(KnockEvent(time: 0.25, peak: 0.11, attackSamples: 3))
        XCTAssertEqual(singles.count, 2)
        XCTAssertEqual(doubles, 0)
    }
}
