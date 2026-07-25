import Foundation

/// The alias↔element pairing behind `@eN` (SU3).
///
/// `elements --format outline` numbers its lines `@e1`, `@e2`, … and records what
/// each one was. A later `tap '@e9'` names that line rather than re-describing the
/// element, which is both shorter and unambiguous where a bare label is not — in
/// Settings, 12 of 45 actionable elements carry neither label nor identifier, and
/// 24 of 45 share their `(type, label, identifier)` with another element. An alias
/// is the only handle that separates those.
///
/// An alias is a claim about a screen that has since been free to change, so it is
/// **re-validated, never trusted**: resolution re-derives the list from the live
/// tree and checks that position N still holds the same identity. Returning the
/// cached coordinates instead would tap wherever that row used to be.
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
    /// The alias is out of range, the app changed, or position N now holds a
    /// different element. All three mean the same thing to a caller: re-run
    /// `elements --format outline` and use a fresh alias.
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
    /// label nor identifier, and 24 of 45 share an identity with another
    /// element). Saying so beats resolving to a plausible wrong element.
    static func unsupported(_ command: String, reason: Reason = .needsElement) -> Data {
        HTTPResponseBuilder.error(
            unsupportedMessage(command, reason: reason),
            code: "alias_unsupported"
        )
    }

    enum Reason {
        /// `pinch`, `slider`, `screenshot --element`, `swipe`, `drag`.
        case needsElement
        /// `assert`, `wait`, and any command combining an alias with a wait — an
        /// alias names a list that was already read, so it cannot become valid by
        /// waiting; it can only go stale.
        case cannotBePolled
        /// `scroll-to`: the alias is on screen by construction, and the first
        /// swipe would invalidate it.
        case alreadyOnScreen

        var explanation: String {
            switch self {
            case .needsElement:
                return "it needs a real element and an alias resolves to a coordinate."
            case .cannotBePolled:
                return "waiting cannot make an alias valid — it names a list you already read."
            case .alreadyOnScreen:
                return "an alias is already on screen, and the first swipe would invalidate it."
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
        return .success(position)
    }
}
