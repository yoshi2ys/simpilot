import Foundation

// MARK: - Scenario File

struct ScenarioFile: Sendable {
    let name: String
    let config: ScenarioConfig
    let variables: [String: String]
    let scenarios: [Scenario]
}

struct ScenarioConfig: Sendable {
    var timeout: Double = 5
    var stopOnFailure: Bool = true
    var screenshotOnFailure: Bool = true
    var screenshotDir: String = "/tmp/simpilot-failures"
}

struct Scenario: Sendable {
    let name: String
    let steps: [Step]
}

struct Step: Sendable {
    let action: StepAction
    let lineNumber: Int
}

// MARK: - Step Actions

enum StepAction: Sendable {
    case launch(bundleId: String)
    case terminate(bundleId: String)
    case activate(bundleId: String)
    case tap(query: String, waitUntil: String?, timeout: Double?)
    case type(text: String, into: String?, method: String?)
    case swipe(direction: String, on: String?, velocity: String?)
    case scrollTo(query: String, direction: String?, maxSwipes: Int?)
    case longpress(query: String, duration: Double?)
    case doubletap(query: String)
    case drag(query: String?, to: String?, toX: Double?, toY: Double?,
              fromX: Double?, fromY: Double?, duration: Double?)
    case pinch(query: String?, scale: Double, velocity: String?)
    case wait(query: String, timeout: Double?, gone: Bool)
    case assert(predicate: String, query: String, expected: String?, timeout: Double?)
    case screenshot(file: String?, scale: String?, element: String?,
                    format: String?, quality: Int?)
    case elements(level: Int?, type: String?, contains: String?)
    case sleep(seconds: Double)
}

// MARK: - Results

struct StepResult {
    enum Status { case passed, failed, skipped }

    let step: Step
    let status: Status
    let durationMs: Int
    let error: String?
    let screenshotPath: String?
}

struct ScenarioResult {
    let name: String
    let stepResults: [StepResult]
    let durationMs: Int

    var passed: Bool { stepResults.allSatisfy { $0.status != .failed } }
}

struct RunResult {
    let file: String
    let scenarioResults: [ScenarioResult]
    let durationMs: Int

    var totalPassed: Int { scenarioResults.flatMap(\.stepResults).count { $0.status == .passed } }
    var totalFailed: Int { scenarioResults.flatMap(\.stepResults).count { $0.status == .failed } }
    var totalSkipped: Int { scenarioResults.flatMap(\.stepResults).count { $0.status == .skipped } }
}
