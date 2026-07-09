import Foundation

/// Identifies a process by PID *and* its kernel-reported start time.
///
/// A bare `kill(pid, 0) == 0` liveness check is unsound: PIDs are recycled, so
/// a long-dead agent's PID can come back as an unrelated process — which
/// `simpilot list` would report as running and `simpilot stop` would SIGTERM.
/// Pairing the PID with its start time makes the identity unambiguous, because
/// the kernel assigns that timestamp at exec and never rewrites it.
enum ProcessIdentity {
    /// Start time of `pid` as seconds since the epoch, or nil when no such
    /// process exists.
    static func startTime(pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        // A vanished PID yields rc == 0 with a zero-length result rather than
        // an error, so the size check is what actually detects "not running".
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }

        let started = info.kp_proc.p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }

    /// Whether `pid` is still the same process that was recorded.
    ///
    /// `recordedStartTime == nil` means the record predates start-time
    /// tracking; those fall back to a plain existence check.
    static func isAlive(pid: Int32, recordedStartTime: Double?) -> Bool {
        guard let actual = startTime(pid: pid) else { return false }
        guard let recorded = recordedStartTime else { return true }
        return matches(actual, recorded)
    }

    /// Start times round-trip through JSON as doubles; compare with a
    /// microsecond-scale tolerance rather than for exact equality.
    static func matches(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.001
    }
}
