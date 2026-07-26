import Foundation

/// The alias↔element pairing behind `@eN` (SU3).
///
/// `elements --format outline` numbers its lines `@e1`, `@e2`, … and records what
/// each one was. A later `tap '@e9'` names that line rather than re-describing the
/// element, which is both shorter and unambiguous where a bare label is not — in
/// Settings, 12 of 45 actionable elements carry neither label nor identifier, and
/// 28 of 45 share their `(type, label, identifier)` with another element. An alias
/// is the only handle that separates those.
///
/// An alias is a claim about a screen that has since been free to change, so it is
/// **re-validated, never trusted**: resolution re-derives the list from the live
/// tree and checks that position N — and the element on either side of it — still
/// holds the same identity. Returning the cached coordinates instead would tap
/// wherever that row used to be.
struct ElementSnapshot {

    /// What is compared across time. Frames are deliberately excluded: scrolling
    /// moves every row without changing which row it is, so requiring frame
    /// proximity would invalidate aliases exactly when they are most useful.
    struct Identity: Equatable {
        let type: String
        let label: String
        let identifier: String

        init(type: String, label: String, identifier: String) {
            self.type = type
            self.label = label
            self.identifier = identifier
        }

        /// Reads the element dictionaries `parseActionableList` produces.
        init(element: [String: Any]) {
            self.init(
                type: element["type"] as? String ?? "",
                label: element["label"] as? String ?? "",
                identifier: element["identifier"] as? String ?? ""
            )
        }
    }

    /// The app the snapshot was taken against. An alias resolved after switching
    /// apps is stale by construction, whatever the identities happen to say.
    let bundleId: String?
    /// The tree depth the list was derived at. Recorded because `--depth` changes
    /// how many elements the list holds: re-deriving at a different depth would
    /// compare position N of two differently-sized lists, which silently shifts
    /// every alias rather than reporting anything.
    let depth: Int
    /// Position N-1 holds `@eN`.
    let identities: [Identity]

    init(bundleId: String?, depth: Int, elements: [[String: Any]]) {
        self.bundleId = bundleId
        self.depth = depth
        self.identities = elements.map(Identity.init(element:))
    }
}

enum AliasResolutionError: Error, Equatable {
    /// No `elements --format outline` has run yet on this agent.
    case noSnapshot
    /// The alias is out of range, the app changed, position N now holds a
    /// different element, or the element beside it does (the list shifted). All of
    /// them mean the same thing to a caller: re-run `elements --format outline` and
    /// use a fresh alias.
    case stale(String)
}

/// One envelope for every alias failure, so `tap`, `scroll-to`, `type` and `drag`
/// cannot describe the same condition three ways. The hint is the whole point:
/// an agent that reads `element_not_found` goes hunting for a label, while the
/// actual repair is always the same — list the screen again.
enum AliasResponse {
    static func unsupportedMessage(_ command: String, reason: Reason = .needsElement) -> String {
        "\(command) does not take an @eN alias: \(reason.explanation) "
            + "Use the element's label or #identifier."
    }

    static func error(_ error: AliasResolutionError) -> Data {
        switch error {
        case .noSnapshot:
            return HTTPResponseBuilder.error(
                "no outline has been taken yet; run `elements --format outline` before using an @eN alias",
                code: "no_snapshot"
            )
        case .stale(let detail):
            return HTTPResponseBuilder.error(
                "\(detail). Run `elements --format outline` again for fresh aliases.",
                code: "stale_alias"
            )
        }
    }

    /// Commands whose gesture needs an `XCUIElement` rather than a point —
    /// `pinch(withScale:)`, `adjust(toNormalizedSliderPosition:)`,
    /// `XCUIElement.screenshot()`. An alias resolves to an identity and a
    /// coordinate; turning it back into a query is not possible in general
    /// (measured on iOS Settings: 12 of 45 actionable elements carry neither
    /// label nor identifier, and 28 of 45 share an identity with another
    /// element). Saying so beats resolving to a plausible wrong element.
    static func unsupported(_ command: String, reason: Reason = .needsElement) -> Data {
        HTTPResponseBuilder.error(
            unsupportedMessage(command, reason: reason),
            code: "alias_unsupported"
        )
    }

    enum Reason: CaseIterable {
        /// `pinch`, `slider`, `screenshot --element`, `swipe`, `drag`.
        case needsElement
        /// `assert`, `wait`, and any command combining an alias with a wait — an
        /// alias names a list that was already read, so it cannot become valid by
        /// waiting; it can only go stale.
        case cannotBePolled
        /// `scroll-to`: the alias is on screen by construction, and the first
        /// swipe would invalidate it.
        case alreadyOnScreen
        /// tvOS: there is no coordinate path to hand the resolved point to.
        case notCoordinateDriven

        var explanation: String {
            switch self {
            case .needsElement:
                return "it needs a real element and an alias resolves to a coordinate."
            case .cannotBePolled:
                return "waiting cannot make an alias valid — it names a list you already read."
            case .alreadyOnScreen:
                return "an alias is already on screen, and the first swipe would invalidate it."
            case .notCoordinateDriven:
                return "this platform moves focus with the remote, and an alias resolves to a coordinate."
            }
        }
    }
}

enum AliasResolver {

    /// `@e` followed by digits, and nothing else. A typed prefix always wins, so
    /// `button:@e9` still means "the button labeled `@e9`" — the escape hatch for
    /// an app that really does label something that way.
    ///
    /// The `e` is not decoration: `@` starts plenty of real labels (handles,
    /// mentions), so a bare `@9` would collide with the literal element a caller
    /// meant to name.
    static func isAlias(_ query: String) -> Bool {
        index(of: query) != nil
    }

    /// Whether an alias can be acted on at all here.
    ///
    /// An alias resolves to a coordinate, and tvOS has no coordinate path to hand
    /// one to: `resolveAndTap` / `resolveAndType` compile their whole
    /// debugDescription fast path out under `#if !os(tvOS)` and drive the UI with
    /// `XCUIRemote` focus instead. Without this, an alias on tvOS falls through to
    /// `ElementResolver` and is matched as the literal label `@e1`, so the caller
    /// is told `element_not_found` and goes hunting for a label that never existed.
    ///
    /// A runtime constant rather than an `#if` at each call site, for two reasons:
    /// the guard is then *compiled on every platform*, so an iOS build typechecks
    /// it (the tvOS branches themselves are not), and the platform fact has one
    /// owner instead of a conditional per handler that can drift apart.
    static let isSupportedOnThisPlatform: Bool = {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }()

    /// The 1-based number in `@eN`, or nil when this is not an alias.
    static func index(of query: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@e") else { return nil }
        let digits = trimmed.dropFirst(2)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits), value >= 1 else {
            return nil
        }
        return value
    }

    /// Validates `alias` against a freshly derived list and returns the position to
    /// read from `fresh`.
    ///
    /// Pure so the whole matrix — no snapshot, app switched, list shortened,
    /// identity changed, list merely reordered — is testable without a simulator.
    /// A rule that can only run against a live app is a rule no test can mutate.
    /// The staleness rules that need the element's *geometry* (it left the parsed
    /// tree; its frame is zero-sized) stay at the call site in
    /// `DebugDescriptionParser.resolve` for the same reason — new rules belong
    /// here unless they need a live screen.
    static func resolve(
        alias: String,
        snapshot: ElementSnapshot?,
        currentBundleId: String?,
        fresh: [ElementSnapshot.Identity]
    ) -> Result<Int, AliasResolutionError> {
        guard let index = index(of: alias) else {
            return .failure(.stale("'\(alias)' is not an alias"))
        }
        guard let snapshot else {
            return .failure(.noSnapshot)
        }
        guard snapshot.bundleId == currentBundleId else {
            return .failure(.stale(
                "\(alias) was taken against \(snapshot.bundleId ?? "no app"), current app is \(currentBundleId ?? "none")"
            ))
        }
        let position = index - 1
        guard position < snapshot.identities.count else {
            return .failure(.stale("\(alias) is beyond the \(snapshot.identities.count) elements in the last outline"))
        }
        guard position < fresh.count else {
            return .failure(.stale("the screen now has \(fresh.count) elements; \(alias) no longer exists"))
        }
        guard fresh[position] == snapshot.identities[position] else {
            return .failure(.stale("\(alias) now points at a different element; the screen changed"))
        }
        if let side = shiftedNeighbour(position: position, recorded: snapshot.identities, fresh: fresh) {
            return .failure(.stale(
                "\(alias) still matches at position \(index), but the element \(side) it no longer matches; the list shifted"
            ))
        }
        return .success(position)
    }

    /// The ±1 window that turns "position N looks the same" into "position N *is*
    /// the same row".
    ///
    /// Identity alone is not enough because most rows have no name to compare: the
    /// nameless and duplicated rows counted above (General: 19 of 30; Keyboard: 26
    /// of 91) compare equal to each other, so a stale alias resolves and taps
    /// whatever now sits there — observed live on iOS 27: an `@e3` recorded on
    /// General resolved against the Settings root and opened the Apple Account
    /// sign-in sheet with `success: true`.
    ///
    /// The dangerous case is not navigation (root vs General agree at exactly one
    /// position) but a shift within one screen: these lists repeat with period 3
    /// (`cell` / `button "…"` / `image chevron.forward`), so inserting a single row
    /// leaves half the positions matching: 21 of the 42 root positions a shift of 3
    /// leaves comparable, and 14 of General's 27. One row appearing or disappearing
    /// is an everyday event. Comparing the neighbours drops all of those to 0.
    ///
    /// Why ±1 rather than the alternatives, all measured on the same screens:
    /// requiring the list *length* to match kills scrolling outright (one swipe on
    /// Keyboard takes 66 elements to 63); refusing any non-unique identity would
    /// reject 62% of the root, which is precisely the nameless rows an alias is the
    /// only handle for. The window costs 1 alias in 49 across a scroll, and that one
    /// fails loudly as `stale_alias`.
    ///
    /// A slot missing from either list is skipped rather than counted as a
    /// mismatch, so appending a row does not invalidate earlier aliases.
    ///
    /// The hole this leaves, deliberately: a run of rows identical to their
    /// neighbours too — a grid of nameless cells — is indistinguishable without
    /// frames, and frames are excluded on purpose. There, a shifted alias still
    /// resolves to the row beside the one recorded.
    private static func shiftedNeighbour(
        position: Int,
        recorded: [ElementSnapshot.Identity],
        fresh: [ElementSnapshot.Identity]
    ) -> String? {
        for (offset, side) in [(-1, "before"), (1, "after")] {
            let neighbour = position + offset
            guard neighbour >= 0, neighbour < recorded.count, neighbour < fresh.count else { continue }
            if recorded[neighbour] != fresh[neighbour] { return side }
        }
        return nil
    }
}
