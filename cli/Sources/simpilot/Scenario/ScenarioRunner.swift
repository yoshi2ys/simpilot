import Foundation

enum ScenarioRunner {

    /// Run all scenarios in a file and return the aggregate result.
    static func run(file: ScenarioFile, client: HTTPClient) -> RunResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let scenarioResults = file.scenarios.map {
            runScenario($0, client: client, config: file.config)
        }
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        return RunResult(file: file.name, scenarioResults: scenarioResults, durationMs: elapsed)
    }

    /// Run a single scenario.
    private static func runScenario(
        _ scenario: Scenario, client: HTTPClient, config: ScenarioConfig
    ) -> ScenarioResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        var stepResults: [StepResult] = []
        var failed = false

        for (i, step) in scenario.steps.enumerated() {
            if failed && config.stopOnFailure {
                stepResults.append(StepResult(
                    step: step, status: .skipped, durationMs: 0,
                    error: nil, screenshotPath: nil
                ))
                continue
            }

            let stepStart = CFAbsoluteTimeGetCurrent()
            var success = true
            var errorMsg: String?
            var screenshotPath: String?

            do {
                let json = try StepExecutor.execute(step.action, client: client, config: config)
                success = StepExecutor.isSuccess(json)
                if !success {
                    errorMsg = StepExecutor.errorMessage(json)
                }
            } catch let cliError as CLIError {
                success = false
                switch cliError {
                case .agentUnreachable(let url):
                    errorMsg = "agent unreachable at \(url)"
                case .agentTimeout(let url, let seconds):
                    errorMsg = "agent at \(url) timed out after \(Int(seconds))s"
                case .invalidURL(let url):
                    errorMsg = "invalid URL: \(url)"
                case .invalidArgs(let msg):
                    errorMsg = msg
                case .commandFailed(let msg):
                    errorMsg = msg
                }
            } catch {
                success = false
                errorMsg = error.localizedDescription
            }

            // Screenshot on failure
            if !success && config.screenshotOnFailure {
                screenshotPath = captureFailureScreenshot(
                    client: client, config: config,
                    scenarioName: scenario.name, stepIndex: i
                )
            }

            let stepMs = Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000)
            stepResults.append(StepResult(
                step: step, status: success ? .passed : .failed, durationMs: stepMs,
                error: (errorMsg?.isEmpty == true) ? nil : errorMsg,
                screenshotPath: screenshotPath
            ))

            if !success {
                failed = true
            }
        }

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        return ScenarioResult(
            name: scenario.name,
            stepResults: stepResults,
            durationMs: elapsed
        )
    }

    /// Attempt to capture a screenshot for failure diagnostics.
    /// Returns the file path on success, nil on failure (best-effort).
    /// File name for a failure screenshot: the scenario name with path- and
    /// shell-hostile characters folded to `_`, plus the 1-based step number.
    static func failureScreenshotFileName(scenarioName: String, stepIndex: Int) -> String {
        let safeName = scenarioName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "\(safeName)_step\(stepIndex + 1).png"
    }

    private static func captureFailureScreenshot(
        client: HTTPClient, config: ScenarioConfig,
        scenarioName: String, stepIndex: Int
    ) -> String? {
        let fileName = failureScreenshotFileName(scenarioName: scenarioName, stepIndex: stepIndex)
        let filePath = (config.screenshotDir as NSString).appendingPathComponent(fileName)

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            atPath: config.screenshotDir,
            withIntermediateDirectories: true
        )

        var components = URLComponents()
        components.path = "/screenshot"
        components.queryItems = [URLQueryItem(name: "file", value: filePath)]
        let path = components.string ?? "/screenshot?file=\(filePath)"

        let screenshotTimeout = config.timeout + HTTPClient.operationBuffer
        guard let data = try? client.get(path, timeout: screenshotTimeout),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              StepExecutor.isSuccess(json) else {
            return nil
        }
        return filePath
    }
}
