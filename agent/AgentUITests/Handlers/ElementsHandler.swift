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
        let resolvedBundleId: String?
        if let bundleId = bundleId, !bundleId.isEmpty {
            app = appManager.app(for: bundleId)
            resolvedBundleId = bundleId
        } else {
            app = appManager.currentApp()
            resolvedBundleId = appManager.currentBundleId
        }

        let responseData: Any

        // Use DebugDescriptionParser for all modes — ~50x faster than
        // walking the XCUITest element tree via children(matching:).
        switch mode {
        case "summary":
            var data = DebugDescriptionParser.parseSummary(from: app)
            if let bid = resolvedBundleId { data["app"] = bid }
            responseData = data

        case "actionable":
            let actionableDepth = Int(request.queryParams["depth"] ?? "20") ?? 20
            let elements = DebugDescriptionParser.parseActionableList(from: app, maxDepth: actionableDepth)
            var data: [String: Any] = ["elements": elements]
            if let bid = resolvedBundleId { data["app"] = bid }
            responseData = data

        case "compact":
            var data: [String: Any] = ["tree": DebugDescriptionParser.parseCompactTree(from: app, maxDepth: depth)]
            if let bid = resolvedBundleId { data["app"] = bid }
            responseData = data

        default:
            var data: [String: Any] = ["tree": DebugDescriptionParser.parseTree(from: app, maxDepth: depth)]
            if let bid = resolvedBundleId { data["app"] = bid }
            responseData = data
        }

        return HTTPResponseBuilder.json(responseData)
    }
}
