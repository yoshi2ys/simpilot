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
        let typeFilter = request.queryParams["type"]
        let containsFilter = request.queryParams["contains"]
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
            var elements = DebugDescriptionParser.parseActionableList(from: app, maxDepth: actionableDepth)
            elements = Self.applyFilters(elements, type: typeFilter, contains: containsFilter)
            responseData = ["elements": elements]

        case "compact":
            responseData = ["tree": DebugDescriptionParser.parseCompactTree(from: app, maxDepth: depth)]

        default:
            responseData = ["tree": DebugDescriptionParser.parseTree(from: app, maxDepth: depth)]
        }

        if let bid = appManager.currentBundleId { responseData["app"] = bid }

        return HTTPResponseBuilder.json(responseData)
    }

    /// Filter actionable elements by type and/or label substring. Both are
    /// case-insensitive; when both are specified they combine as AND.
    static func applyFilters(
        _ elements: [[String: Any]],
        type: String?,
        contains: String?
    ) -> [[String: Any]] {
        let allowedTypes: Set<String>? = type.map { raw in
            Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        }
        let needle = contains?.lowercased()

        if allowedTypes == nil && needle == nil { return elements }

        return elements.filter { element in
            if let allowedTypes {
                guard let t = element["type"] as? String, allowedTypes.contains(t.lowercased()) else {
                    return false
                }
            }
            if let needle {
                guard let label = element["label"] as? String, label.lowercased().contains(needle) else {
                    return false
                }
            }
            return true
        }
    }
}
