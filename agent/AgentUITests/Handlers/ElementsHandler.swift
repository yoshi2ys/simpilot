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
        let requestedFormat = request.queryParams["format"] ?? "json"
        let format = requestedFormat.lowercased()
        guard Self.isSupportedFormat(format) else {
            return HTTPResponseBuilder.error(
                "unknown format '\(requestedFormat)' (expected 'json' or 'outline')",
                code: "invalid_request"
            )
        }

        let mode = Self.resolveMode(level: levelParam, mode: request.queryParams["mode"])

        if Self.outlineConflictsWithRequestedMode(
            format: format, level: levelParam, mode: request.queryParams["mode"]
        ) {
            return HTTPResponseBuilder.error(
                "format=outline renders the actionable list only; drop the level/mode parameter or use level=1",
                code: "invalid_request"
            )
        }

        let app: XCUIApplication
        do {
            app = try appManager.resolveApp(bundleId: bundleId)
        } catch {
            return HTTPResponseBuilder.error(error.localizedDescription, code: "activate_failed")
        }
        var responseData: [String: Any]

        if format == "outline" {
            let rendered = OutlineRenderer.render(
                actionableElements(from: app, request: request, type: typeFilter, contains: containsFilter)
            )
            responseData = ["outline": rendered.text, "count": rendered.entries.count]
        } else {
            switch mode {
            case "summary":
                responseData = DebugDescriptionParser.parseSummary(from: app)

            case "actionable":
                responseData = [
                    "elements": actionableElements(
                        from: app, request: request, type: typeFilter, contains: containsFilter
                    )
                ]

            case "compact":
                responseData = ["tree": DebugDescriptionParser.parseCompactTree(from: app, maxDepth: depth)]

            default:
                responseData = ["tree": DebugDescriptionParser.parseTree(from: app, maxDepth: depth)]
            }
        }

        if let bid = appManager.currentBundleId { responseData["app"] = bid }

        return HTTPResponseBuilder.json(responseData)
    }

    // MARK: - Request rules (pure — testable without a live app)
    //
    // These three are static functions rather than inline checks in `handle` for
    // the reason A34 recorded: a rule buried in `handle` can only be exercised
    // against a running simulator, so a mutation to it passes the whole suite.

    /// Compared against the lowercased value, because the endpoints are documented
    /// as directly curl-able and the CLI's `ElementsFormatArg` already lowercases —
    /// `?format=OUTLINE` must not be rejected here when the CLI accepts it.
    static func isSupportedFormat(_ format: String) -> Bool {
        format == "json" || format == "outline"
    }

    /// `level` wins over `mode`; a non-numeric or absent `level` falls back to
    /// `mode`, and the default is the full tree.
    static func resolveMode(level: String?, mode: String?) -> String {
        guard let level, let numeric = Int(level) else { return mode ?? "tree" }
        switch numeric {
        case 0: return "summary"
        case 1: return "actionable"
        case 2: return "compact"
        default: return "tree"
        }
    }

    /// Outline is a flat one-line-per-element shape, so it can only render the
    /// actionable list — the tree modes carry nesting it has nowhere to put. A
    /// caller who *explicitly* asked for another level is told so rather than
    /// handed the actionable list under a `success: true`, the same way
    /// `DragHandler` rejects conflicting targets instead of silently picking one.
    ///
    /// Only an explicit parameter conflicts: with neither present `resolveMode`
    /// returns its `tree` default, which is an absence, not a request.
    static func outlineConflictsWithRequestedMode(format: String, level: String?, mode: String?) -> Bool {
        guard format == "outline", level != nil || mode != nil else { return false }
        return resolveMode(level: level, mode: mode) != "actionable"
    }

    /// The level-1 element list: parse, then apply the query filters. Shared by
    /// the JSON and outline formats, so a change to the depth default or to the
    /// filter set cannot land on one and silently miss the other.
    private func actionableElements(
        from app: XCUIApplication,
        request: HTTPRequest,
        type: String?,
        contains: String?
    ) -> [[String: Any]] {
        let depth = Int(request.queryParams["depth"] ?? "20") ?? 20
        let elements = DebugDescriptionParser.parseActionableList(from: app, maxDepth: depth)
        return Self.applyFilters(elements, type: type, contains: contains)
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
