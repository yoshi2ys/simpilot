import Foundation
import XCTest

final class ElementsHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        let bundleId = request.queryParams["bundleId"]
        let depth = Int(request.queryParams["depth"] ?? "3") ?? 3
        let levelParam = request.queryParams["level"]
        let mode: String

        if let levelStr = levelParam, let level = Int(levelStr) {
            switch level {
            case 0: mode = "summary"
            case 1: mode = "actionable"
            case 2: mode = "compact"
            default: mode = "tree"
            }
        } else {
            mode = request.queryParams["mode"] ?? "tree"
        }

        let app: XCUIApplication
        do {
            app = try appManager.resolveApp(bundleId: bundleId)
        } catch {
            return HTTPResponseBuilder.error(error.localizedDescription, code: "activate_failed")
        }
        var responseData: [String: Any]

        switch mode {
        case "summary":
            responseData = DebugDescriptionParser.parseSummary(from: app)

        case "actionable":
            let actionableDepth = Int(request.queryParams["depth"] ?? "20") ?? 20
            let elements = DebugDescriptionParser.parseActionableList(from: app, maxDepth: actionableDepth)
            responseData = ["elements": elements]

        case "compact":
            responseData = ["tree": DebugDescriptionParser.parseCompactTree(from: app, maxDepth: depth)]

        default:
            responseData = ["tree": DebugDescriptionParser.parseTree(from: app, maxDepth: depth)]
        }

        if let bid = appManager.currentBundleId { responseData["app"] = bid }

        return HTTPResponseBuilder.json(responseData)
    }
}
