import Foundation

enum RunReporter {

    /// Print results in human-readable terminal format to stderr, then print
    /// a summary. Keeps stdout clean for piping.
    static func reportTerminal(_ result: RunResult) {
        for sr in result.scenarioResults {
            stderrLine("\n--- \(sr.name) ---")
            for (i, step) in sr.stepResults.enumerated() {
                let label = stepLabel(step.step.action)
                let timing = "\(step.durationMs)ms"

                if step.status == .skipped {
                    stderrLine("  [\(i + 1)] [SKIP] \(label)")
                } else if step.status == .passed {
                    stderrLine("  [\(i + 1)] [PASS] \(label) (\(timing))")
                } else {
                    stderrLine("  [\(i + 1)] [FAIL] \(label) (\(timing))")
                    if let err = step.error {
                        stderrLine("         \(err)")
                    }
                    if let path = step.screenshotPath {
                        stderrLine("         screenshot: \(path)")
                    }
                }
            }
            let status = sr.passed ? "PASSED" : "FAILED"
            stderrLine("  => \(status) (\(sr.durationMs)ms)")
        }

        // Summary
        let total = result.totalPassed + result.totalFailed + result.totalSkipped
        stderrLine("\n=== \(result.file) ===")
        stderrLine("  \(total) steps: \(result.totalPassed) passed, \(result.totalFailed) failed, \(result.totalSkipped) skipped (\(result.durationMs)ms)")

        let allPassed = result.totalFailed == 0
        stderrLine(allPassed ? "  Result: PASS" : "  Result: FAIL")
    }

    /// Print results as structured JSON to stdout.
    static func reportJSON(_ result: RunResult, pretty: Bool) {
        let json = buildJSON(result)
        printJSON(json, pretty: pretty)
    }

    // MARK: - JSON Builder

    private static func buildJSON(_ result: RunResult) -> [String: Any] {
        [
            "success": result.totalFailed == 0,
            "data": [
                "file": result.file,
                "scenarios": result.scenarioResults.map { sr -> [String: Any] in
                    [
                        "name": sr.name,
                        "passed": sr.passed,
                        "duration_ms": sr.durationMs,
                        "steps": sr.stepResults.map { step -> [String: Any] in
                            var s: [String: Any] = [
                                "action": stepLabel(step.step.action),
                                "status": "\(step.status)",
                                "duration_ms": step.durationMs,
                            ]
                            if let err = step.error { s["error"] = err }
                            if let path = step.screenshotPath { s["screenshot"] = path }
                            return s
                        }
                    ]
                },
                "total_passed": result.totalPassed,
                "total_failed": result.totalFailed,
                "total_skipped": result.totalSkipped,
                "duration_ms": result.durationMs,
            ] as [String: Any]
        ]
    }

    // MARK: - Step Label

    static func stepLabel(_ action: StepAction) -> String {
        switch action {
        case .launch(let id): return "launch \(id)"
        case .terminate(let id): return "terminate \(id)"
        case .activate(let id): return "activate \(id)"
        case .tap(let q, _, _): return "tap '\(q)'"
        case .type(let t, let into, _):
            if let into { return "type '\(t)' into '\(into)'" }
            return "type '\(t)'"
        case .swipe(let d, let on, _):
            if let on { return "swipe \(d) on '\(on)'" }
            return "swipe \(d)"
        case .scrollTo(let q, _, _): return "scroll-to '\(q)'"
        case .longpress(let q, _): return "longpress '\(q)'"
        case .doubletap(let q): return "doubletap '\(q)'"
        case .drag(let q, let to, _, _, _, _, _):
            let from = q ?? "coord"
            let dest = to ?? "coord"
            return "drag '\(from)' to '\(dest)'"
        case .pinch(let q, let s, _):
            let target = q ?? "screen"
            return "pinch '\(target)' scale=\(s)"
        case .wait(let q, _, let gone):
            return gone ? "wait-gone '\(q)'" : "wait '\(q)'"
        case .assert(let p, let q, _, _): return "assert \(p) '\(q)'"
        case .screenshot(let f, _, _, _, _):
            if let f { return "screenshot \(f)" }
            return "screenshot"
        case .elements(let level, _, _):
            if let level { return "elements level=\(level)" }
            return "elements"
        case .sleep(let s): return "sleep \(s)s"
        }
    }

    // MARK: - stderr

    private static func stderrLine(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}
