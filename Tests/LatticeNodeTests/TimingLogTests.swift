import XCTest
@testable import LatticeNode

/// The gate is a module-level `let` evaluated once at process start, so we
/// can't flip it at test time. We verify the call shape instead: timingLog
/// must accept an autoclosure (so string interpolation is skipped when
/// disabled) and must be safe to call regardless of the gate's value.
final class TimingLogTests: XCTestCase {

    func testTimingLogDoesNotEvaluateAutoclosureWhenDisabled() {
        // When LATTICE_TIMING isn't set (the test default), the @autoclosure
        // must not run — otherwise the whole gating exercise is pointless.
        var sideEffectRan = false
        func sideEffect() -> String {
            sideEffectRan = true
            return "should never appear"
        }

        if !timingLogEnabled {
            timingLog(sideEffect())
            XCTAssertFalse(sideEffectRan,
                "autoclosure must be skipped when LATTICE_TIMING is off")
        } else {
            // If the runner happens to have LATTICE_TIMING=1, the side effect
            // runs; still assert the helper doesn't crash.
            timingLog(sideEffect())
            XCTAssertTrue(sideEffectRan)
        }
    }

    func testDefaultGateIsOff() {
        // Fresh processes must default to off — on-by-default would re-introduce
        // the perf-noise regression this change fixed.
        let env = ProcessInfo.processInfo.environment["LATTICE_TIMING"] ?? ""
        if env.isEmpty || env == "0" {
            XCTAssertFalse(timingLogEnabled)
        }
    }
}
