import XCTest
@testable import LatticeNode

final class SubmitTimeoutTests: XCTestCase {

    func testRaceReturnsTrueWhenWorkCompletesBeforeTimeout() async {
        let finished = await raceSubmitWithTimeout(
            timeout: .seconds(5),
            work: {
                try? await Task.sleep(for: .milliseconds(50))
            }
        )
        XCTAssertTrue(finished, "fast work must complete within timeout")
    }

    func testRaceReturnsFalseWhenWorkExceedsTimeout() async {
        let start = ContinuousClock.now
        let finished = await raceSubmitWithTimeout(
            timeout: .milliseconds(100),
            work: {
                // Simulate a wedged delegate by sleeping far past timeout.
                try? await Task.sleep(for: .seconds(30))
            }
        )
        let elapsed = ContinuousClock.now - start
        XCTAssertFalse(finished, "timeout must fire when work overruns")
        // We must return well before the work's 30s sleep — proving the
        // orphan-and-continue pattern actually unblocks the caller.
        XCTAssertLessThan(elapsed, .seconds(2), "timeout must release caller promptly")
    }

    func testRaceReturnsPromptlyWhenWorkIsInstant() async {
        let start = ContinuousClock.now
        let finished = await raceSubmitWithTimeout(
            timeout: .seconds(60),
            work: { }
        )
        let elapsed = ContinuousClock.now - start
        XCTAssertTrue(finished)
        // The non-timeout branch must not wait the full timeout window.
        XCTAssertLessThan(elapsed, .seconds(1), "winner short-circuits the timeout")
    }
}
