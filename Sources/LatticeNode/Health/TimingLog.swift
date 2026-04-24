import Foundation

/// `true` when the env var `LATTICE_TIMING` is set to anything other than
/// empty/"0". Evaluated once at process start — flipping the env mid-run
/// has no effect. Off by default: the [TIMING] lines are useful under
/// perf investigation but noisy otherwise.
let timingLogEnabled: Bool = {
    guard let v = ProcessInfo.processInfo.environment["LATTICE_TIMING"] else { return false }
    return !v.isEmpty && v != "0"
}()

func timingLog(_ message: @autoclosure () -> String) {
    if timingLogEnabled { print(message()) }
}
