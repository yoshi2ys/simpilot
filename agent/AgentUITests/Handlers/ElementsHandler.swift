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
            // Rendered without the filters, so `@eN` numbers the whole actionable
            // list: a filtered outline that renumbered from 1 would hand out
            // aliases that resolve against a list the agent never derives, and the
            // filters exist to shorten *reading*, not to redefine the addresses.
            let outlineDepth = Self.actionableDepth(from: request)
            let listing = DebugDescriptionParser.parseActionable(from: app, maxDepth: outlineDepth)
            let all = listing.elements
            appManager.recordSnapshot(ElementSnapshot(
                bundleId: appManager.currentBundleId, depth: outlineDepth, elements: all
            ))

            let matcher = Self.filterPredicate(type: typeFilter, contains: containsFilter)
            let shown = OutlineRenderer.render(all).keeping { matcher(all[$0]) }
            responseData = [
                "outline": Self.outlineText(
                    shown.text,
                    lists: listing.lists,
                    withAliasReference: listing.listsAreComparableToAliases
                ),
                "count": shown.entries.count
            ]
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

    /// The outline as the caller receives it: the `# list @lN` header lines, then
    /// the element lines.
    ///
    /// Joined here rather than inside `OutlineRenderer` because the header is not an
    /// entry — `count` counts elements, and `keeping(_:)` filters by element
    /// position, so a header line inside `Rendered` would have to be excluded from
    /// both. A screen with no detected list gets no header and no leading blank
    /// line: an empty section would read as a list that failed to render.
    static func outlineText(
        _ elements: String,
        lists: [ListCluster],
        withAliasReference: Bool = true
    ) -> String {
        let header = ListClusterDetector.outlineHeader(for: lists, withAliasReference: withAliasReference)
        return (header + (elements.isEmpty ? [] : [elements])).joined(separator: "\n")
    }

    /// The level-1 element list for the JSON format: parse, then apply the query
    /// filters. The outline format reads the same list through
    /// `DebugDescriptionParser.parseActionable`, which returns the detected lists
    /// alongside it, and filters by *position* to keep the alias numbering — so what
    /// the two share is the membership rule (`collectActionable`), the depth reading
    /// (`actionableDepth`), and the filter itself (`filterPredicate`), each of which
    /// has one owner.
    private func actionableElements(
        from app: XCUIApplication,
        request: HTTPRequest,
        type: String?,
        contains: String?
    ) -> [[String: Any]] {
        let elements = DebugDescriptionParser.parseActionableList(
            from: app, maxDepth: Self.actionableDepth(from: request)
        )
        return Self.applyFilters(elements, type: type, contains: contains)
    }

    /// One reading of `depth` for the actionable list, so the depth a snapshot
    /// records and the depth its aliases resolve at cannot come from two literals.
    static func actionableDepth(from request: HTTPRequest) -> Int {
        Int(request.queryParams["depth"] ?? "") ?? DebugDescriptionParser.defaultActionableDepth
    }

    /// Filter actionable elements by type and/or label substring. Both are
    /// case-insensitive; when both are specified they combine as AND.
    static func applyFilters(
        _ elements: [[String: Any]],
        type: String?,
        contains: String?
    ) -> [[String: Any]] {
        elements.filter(filterPredicate(type: type, contains: contains))
    }

    /// The per-element half of `applyFilters`, exposed because outline filters by
    /// *position* — it keeps the alias numbering of the unfiltered list, so it
    /// cannot use a function that returns a re-packed array. One predicate for
    /// both callers, so JSON and outline can never disagree about what a filter
    /// matches.
    static func filterPredicate(type: String?, contains: String?) -> ([String: Any]) -> Bool {
        let allowedTypes: Set<String>? = type.map { raw in
            Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        }
        let needle = contains?.lowercased()

        if allowedTypes == nil && needle == nil { return { _ in true } }

        return { element in
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
