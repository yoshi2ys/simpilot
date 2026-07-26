import Foundation

/// A repeating list detected in the element tree, and the `@rN` / `@lMrN`
/// selectors that address its rows (SU4).
///
/// `@eN` (SU3) names a line of an outline that was already read, so it needs a
/// prior `elements --format outline` and goes stale the moment the screen moves. A
/// row selector needs neither: it is re-derived from the live tree on every use, so
/// `tap '@r3'` is one round trip where an alias needs two, and it stays meaningful
/// across the taps and scrolls that invalidate an alias. What it gives up is
/// identity — it names *whatever now sits* at that position, which is why it is
/// refused everywhere the caller would be waiting for one particular element to
/// arrive there (see `AliasResponse.Reason.alreadyOnScreen`).
///
/// The address is not `#N` / `#N@M` as the sim-use comparison sketched it: `#` is
/// already the identifier prefix, so `#2` means "the element whose identifier is
/// `2`", and numeric identifiers are ordinary. Reading `#2` as a row number would
/// be exactly the silent substitution SU3 avoided when it chose `@eN` over `@N`.
struct ListCluster {

    /// One row, paired with its position in the unfiltered actionable list so the
    /// outline header can point at the `@eN` line the list starts on.
    struct Row {
        /// 0-based index into `parseActionableList`'s output. `@e(index + 1)`.
        let actionableIndex: Int
        let element: DebugDescriptionParser.ParsedElement
    }

    /// The shared element type of every row (`cell`, `button`, …).
    let type: String
    /// Top to bottom. Only rows whose centre is inside the viewport are here —
    /// see `ListClusterDetector.detect`.
    let rows: [Row]
}

/// A query that names a *position* rather than describing an element: `@eN`
/// (SU3) and `@rN` / `@lMrN` (SU4).
///
/// The two behave differently — an alias can go stale, a row selector cannot; a
/// row selector can be polled, an alias cannot — but every command that resolves a
/// query to a **coordinate** takes both, and every command that needs a real
/// `XCUIElement` refuses both. Those refusals are the reason this type exists:
/// asking "is this query positional at all" in one place means a handler cannot
/// close the door on one form and leave it open on the other, which is the shape
/// of bug SU3 hit when the tvOS guard was per-call-site.
enum PositionalQuery {
    case alias
    case row

    /// Whether a positional query can be acted on at all here.
    ///
    /// Both forms resolve to a coordinate, and tvOS has no coordinate path to hand
    /// one to: `resolveAndTap` / `resolveAndType` compile their whole
    /// debugDescription fast path out under `#if !os(tvOS)` and drive the UI with
    /// `XCUIRemote` focus instead. Without this, a positional query on tvOS falls
    /// through to `ElementResolver` and is matched as the literal label `@e1` /
    /// `@r1`, so the caller is told `element_not_found` for something that never was
    /// a label.
    ///
    /// A runtime constant rather than an `#if` at each call site, for two reasons:
    /// the guard is then *compiled on every platform*, so an iOS build typechecks it
    /// (the tvOS branches themselves are not), and the platform fact has one owner
    /// instead of a conditional per handler that can drift apart. It lives here
    /// rather than on `AliasResolver` because it is a fact about the coordinate
    /// path, which both forms depend on.
    static let isSupportedOnThisPlatform: Bool = {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }()

    static func kind(of query: String?) -> PositionalQuery? {
        guard let query else { return nil }
        if AliasResolver.isAlias(query) { return .alias }
        if RowSelector.parse(query) != nil { return .row }
        return nil
    }

    /// How the refusal names the form, for a message that tells the caller which
    /// of the two they wrote.
    var description: String {
        switch self {
        case .alias: return "an @eN alias"
        case .row: return "an @rN row selector"
        }
    }

    /// The refusal envelope for this form.
    ///
    /// The alias branch delegates to `AliasResponse`, which owns that envelope —
    /// two builders for one wire shape is what its own doc comment exists to
    /// prevent. The row code is spelled out as a literal because `ErrorHintTests`
    /// reads `code:` literals out of the sources to prove every code has a hint
    /// decision, and a code assembled at runtime is invisible to it.
    func unsupported(_ command: String, reason: SharedReason = .needsElement) -> Data {
        switch self {
        case .alias:
            return AliasResponse.unsupported(command, reason: reason.reason)
        case .row:
            return HTTPResponseBuilder.error(
                AliasResponse.unsupportedMessage(command, kind: .row, reason: reason.reason),
                code: "row_unsupported"
            )
        }
    }

    /// The refusal reasons that are true of **both** forms.
    ///
    /// `AliasResponse.Reason.cannotBePolled` is absent by construction rather than by
    /// convention: a row selector is re-derived from the live tree on every
    /// observation, so it polls perfectly well, and a refusal reading "type with a
    /// wait does not take an @rN row selector: waiting cannot make an alias valid"
    /// would be nonsense a comment cannot prevent. Alias-only sites keep the full
    /// `Reason` through `AliasResponse.unsupported`.
    enum SharedReason {
        case needsElement
        case alreadyOnScreen
        case notCoordinateDriven

        var reason: AliasResponse.Reason {
            switch self {
            case .needsElement: return .needsElement
            case .alreadyOnScreen: return .alreadyOnScreen
            case .notCoordinateDriven: return .notCoordinateDriven
            }
        }
    }

    /// The refusal for a command that takes no positional query, or nil when
    /// `query` is an ordinary one. Callers guard with a single `if let`, so a
    /// command cannot refuse an alias and silently accept a row selector.
    static func refusal(
        for query: String?,
        command: String,
        reason: SharedReason = .needsElement
    ) -> Data? {
        kind(of: query)?.unsupported(command, reason: reason)
    }
}

/// `@rN` (row N of the only list) or `@lMrN` (row N of list M), and nothing else.
///
/// Both numbers are 1-based, like `@eN`. As with an alias, a typed prefix wins —
/// `button:@r3` still means "the button labeled `@r3`" — so an app that really
/// labels something this way keeps an escape hatch.
struct RowSelector: Equatable {
    /// 1-based list number, or nil for the bare `@rN` form, which resolves only
    /// when the screen has exactly one list.
    let list: Int?
    /// 1-based row number, counted top to bottom over the rows on screen.
    let row: Int

    /// The canonical spelling, for messages that quote back what was asked.
    var text: String {
        guard let list else { return "@r\(row)" }
        return "@l\(list)r\(row)"
    }

    /// Parses `@rN` / `@lMrN`. Returns nil for everything else, including the
    /// halves (`@r`, `@l2`, `@l2r`) and zero (`@r0`) — a row number is 1-based, and
    /// accepting 0 as "the first row" would make two spellings mean one row.
    static func parse(_ query: String) -> RowSelector? {
        var rest = Substring(query.trimmingCharacters(in: .whitespaces))
        guard rest.first == "@" else { return nil }
        rest = rest.dropFirst()

        var list: Int?
        if rest.first == "l" {
            rest = rest.dropFirst()
            guard let number = takeNumber(&rest) else { return nil }
            list = number
        }
        guard rest.first == "r" else { return nil }
        rest = rest.dropFirst()
        guard let row = takeNumber(&rest), rest.isEmpty else { return nil }
        return RowSelector(list: list, row: row)
    }

    /// Consumes the leading run of digits. Nil when there is none, or when the
    /// number is not a positive Int.
    private static func takeNumber(_ rest: inout Substring) -> Int? {
        let digits = rest.prefix(while: \.isNumber)
        rest = rest.dropFirst(digits.count)
        guard let value = Int(digits), value >= 1 else { return nil }
        return value
    }
}

/// Why a row selector did not resolve. Each case is its own sentence to the
/// caller because the repairs differ: name the list, scroll the list, or stop
/// using a row selector on this screen.
enum RowResolutionError: Error, Equatable {
    /// No repeating list on this screen at all.
    case noLists(RowSelector)
    /// `@lM` names a list beyond the `count` that were detected. The number is
    /// carried rather than read back off the selector, whose `list` is optional —
    /// a `?? 0` in the message would print a wrong number if this case were ever
    /// raised for the bare form.
    case listNotFound(RowSelector, list: Int, count: Int)
    /// A bare `@rN` on a screen with more than one list. The row counts ride along
    /// so the caller can pick without another round trip.
    case ambiguous(RowSelector, rowsPerList: [Int])
    /// The list exists and has fewer rows on screen than the selector asks for.
    case rowNotFound(RowSelector, rows: Int)
    /// The row resolved, but the coordinate gesture at its centre raised. Kept
    /// distinct from a resolution failure so the caller is not sent to re-read a
    /// screen whose reading was correct.
    case gestureFailed(String)
    /// The row resolved, but a predicate cannot be evaluated against it —
    /// `hittable` re-queries XCUITest by label or identifier, and a row that has
    /// neither (the case a positional handle exists for) would be reported
    /// unhittable whatever the screen shows.
    case notCheckable(RowSelector, predicate: String)
}

/// One envelope per row-selector failure, so `tap`, `type` and the poller cannot
/// describe the same condition three ways. As with `AliasResponse`, the messages
/// state the condition only — the repair rides in `error.hint` (SU2).
enum RowResponse {

    static func message(_ error: RowResolutionError) -> String {
        switch error {
        case .noLists(let selector):
            return "\(selector.text) needs a repeating list, and none was detected on this screen"
        case .listNotFound(let selector, let list, let count):
            return "\(selector.text) names list \(list), but this screen has \(count)"
        case .ambiguous(let selector, let rowsPerList):
            let lists = rowsPerList.enumerated()
                .map { "@l\($0.offset + 1) with \($0.element) rows" }
                .joined(separator: ", ")
            return "\(selector.text) does not say which list: this screen has \(rowsPerList.count) (\(lists))"
        case .rowNotFound(let selector, let rows):
            return "\(selector.text) names row \(selector.row), but that list shows \(rows) rows on screen"
        case .gestureFailed(let detail):
            return detail
        case .notCheckable(let selector, let predicate):
            return "\(predicate) cannot be checked for \(selector.text): the row it names carries no label "
                + "or identifier to re-query, so the answer would not be about that row"
        }
    }

    static func error(_ error: RowResolutionError) -> Data {
        switch error {
        case .noLists, .listNotFound:
            return HTTPResponseBuilder.error(message(error), code: "list_not_found")
        case .ambiguous:
            return HTTPResponseBuilder.error(message(error), code: "ambiguous_list")
        case .rowNotFound:
            return HTTPResponseBuilder.error(message(error), code: "row_not_found")
        case .gestureFailed:
            // The same code a failed coordinate tap reports for an ordinary query:
            // the resolution was fine and the gesture was not, which is what the
            // caller needs to know, and the repair is identical.
            return HTTPResponseBuilder.error(message(error), code: "tap_failed")
        case .notCheckable:
            // The repair is the one `row_unsupported` already carries: name the
            // element instead of its position. Nothing is stale and no list is
            // missing, so neither `stale_alias` nor `row_not_found` would fit.
            return HTTPResponseBuilder.error(message(error), code: "row_unsupported")
        }
    }
}

/// Finds the repeating lists in a parsed tree.
///
/// Deliberately conservative: a false list is worse than a missing one, because a
/// caller who is told "no list here" reaches for a label, while one handed a
/// spurious list taps a row that was never a row. A run therefore has to agree on
/// everything a rendered list agrees on — parent, type, left edge, size, and pitch
/// — before it counts as one.
enum ListClusterDetector {

    /// Point slack for every geometric comparison. Frames come out of
    /// debugDescription rounded to a tenth of a point (`52.0`, `73.7`), so exact
    /// equality would drop lists that a layout pass split across a fraction; a
    /// whole point is still far below the pitch of any real row.
    static let tolerance: Double = 1.0

    /// Two rows are a pair, not a list. Three is the shortest run where "same
    /// size, evenly spaced" says anything that a coincidence would not.
    static let minimumRows = 3

    /// Every list on screen, in the order they appear in the tree.
    ///
    /// Rows are limited to elements whose **centre lies inside the viewport**. The
    /// tree carries rows that are scrolled far out of view — the language-sheet
    /// fixture exposes 53 cells of a list whose bottom row sits at y=3411 on an
    /// 874pt screen — and numbering those in would hand out `@r30` addresses whose
    /// coordinate is off screen, where a tap lands nowhere and reports success.
    /// Limiting to what is visible also removes an error case instead of adding one:
    /// a row a selector can name is a row whose centre is on screen.
    ///
    /// It is *not* a promise that the row is reachable. Visibility here is geometry
    /// against the window frame, with no notion of occlusion — a row behind a sheet,
    /// a dimming overlay or the keyboard is still numbered, and tapping it hits
    /// whatever is on top. This is the coordinate path's standing limitation (the
    /// same reason `hittable` is a separate, more expensive check) rather than
    /// something the detector could fix from the text tree: parse order is not a
    /// reliable z-order proxy, and a modal is not always a `sheet` element — the
    /// `language_sheet_modal` capture builds one out of `Other` containers, so there
    /// is nothing sound to test containment against. On such a screen the covered
    /// list is reported too, which is why a bare `@rN` refuses to guess between
    /// them; naming `@lM` explicitly is the caller taking that risk.
    ///
    /// The cost is that scrolling renumbers the rows. That is inherent to a
    /// positional address, and it is why a row selector is refused wherever the
    /// caller is waiting for something to arrive rather than acting on what is
    /// there now.
    static func detect(
        in elements: [DebugDescriptionParser.ParsedElement],
        maxDepth: Int = DebugDescriptionParser.defaultActionableDepth
    ) -> [ListCluster] {
        guard let viewport = viewport(in: elements) else { return [] }

        // Grouped by (parent, type): siblings of one container. Grouping by depth
        // alone would merge two lists that happen to sit at the same depth under
        // different containers, and their rows would interleave by y into one
        // evenly-spaced run that never existed.
        //
        // Parenthood comes from the same single walk, as a depth stack: a
        // tree-sized parent array would be allocated on every call, and this runs
        // per poll tick when a row selector is combined with a wait.
        var groups: [Group: [ListCluster.Row]] = [:]
        var stack: [Int] = []
        var actionableIndex = 0
        for (index, element) in elements.enumerated() {
            while let last = stack.last, elements[last].depth >= element.depth { stack.removeLast() }
            defer { stack.append(index) }

            guard DebugDescriptionParser.isActionable(element, withinDepth: maxDepth) else { continue }
            // Counts every element `@eN` numbers, visible or not, so a row's
            // `actionableIndex` names the same line the outline does.
            let position = actionableIndex
            actionableIndex += 1
            guard element.frame.w > 0, element.frame.h > 0, isVisible(element, in: viewport) else { continue }
            groups[Group(parent: stack.last ?? -1, type: element.type), default: []]
                .append(ListCluster.Row(actionableIndex: position, element: element))
        }

        var clusters: [ListCluster] = []
        for rows in groups.values {
            let sorted = rows.sorted { ($0.element.frame.y, $0.element.frame.x) < ($1.element.frame.y, $1.element.frame.x) }
            for run in uniformRuns(in: sorted) {
                clusters.append(ListCluster(type: run[0].element.type, rows: run))
            }
        }
        // Ordered by the tree position of the first row, so a list's number matches
        // where it appears in the outline the caller just read. Sorting here is what
        // makes the order deterministic — `groups` is a dictionary, and every
        // cluster's first row has a distinct position in the actionable list.
        return clusters.sorted { $0.rows[0].actionableIndex < $1.rows[0].actionableIndex }
    }

    /// The sibling group a row belongs to: one container, one element type.
    private struct Group: Hashable {
        let parent: Int
        let type: String
    }

    /// Resolve `selector` against the lists of one screen.
    ///
    /// A bare `@rN` resolves only when there is exactly one list. With two, which
    /// one it means is a guess, and guessing is the one thing a positional address
    /// must not do — the alternative (`the largest list`) reads as working right up
    /// to the screen where the largest list is not the one the caller meant.
    static func row(
        for selector: RowSelector,
        in lists: [ListCluster]
    ) -> Result<ListCluster.Row, RowResolutionError> {
        guard !lists.isEmpty else { return .failure(.noLists(selector)) }

        let list: ListCluster
        if let number = selector.list {
            guard number <= lists.count else {
                return .failure(.listNotFound(selector, list: number, count: lists.count))
            }
            list = lists[number - 1]
        } else {
            guard lists.count == 1 else {
                return .failure(.ambiguous(selector, rowsPerList: lists.map { $0.rows.count }))
            }
            list = lists[0]
        }

        guard selector.row <= list.rows.count else {
            return .failure(.rowNotFound(selector, rows: list.rows.count))
        }
        return .success(list.rows[selector.row - 1])
    }

    // MARK: - Outline

    /// The `# list` lines `elements --format outline` prints above its elements.
    ///
    /// Without them a row selector is undiscoverable: an agent reading an outline
    /// has no way to tell that the rows it sees are a detected list, or how many
    /// rows deep it goes. One line per list is a few dozen bytes against the
    /// outline's ~1,200, and it is the only place the two addressing schemes meet —
    /// naming the `@eN` of the first row lets the caller line the list up against
    /// the element lines below.
    ///
    /// `#` opens the line because it cannot be confused with an element line, which
    /// always starts `- `.
    ///
    /// The `first row @eN` cross-reference is dropped when the caller narrowed
    /// `--depth`: lists are detected at the depth `@rN` resolves at, so under a
    /// narrower request the row's position is not the position of the `@eN` line
    /// below. An absent cross-reference beats one that names the wrong line.
    static func outlineHeader(for lists: [ListCluster], withAliasReference: Bool = true) -> [String] {
        lists.enumerated().map { index, list in
            let head = "# list @l\(index + 1): \(list.rows.count) \(list.type) rows"
            guard withAliasReference else { return head }
            return head + ", first row @e\(list.rows[0].actionableIndex + 1)"
        }
    }

    // MARK: - Geometry

    /// The screen, as the tree reports it: the first window (or application) with a
    /// frame. Nil when the tree carries none, in which case there is nothing to
    /// call visible and no lists are reported.
    static func viewport(
        in elements: [DebugDescriptionParser.ParsedElement]
    ) -> (x: Double, y: Double, w: Double, h: Double)? {
        elements.first {
            ($0.type == "window" || $0.type == "application") && $0.frame.w > 0 && $0.frame.h > 0
        }?.frame
    }

    private static func isVisible(
        _ element: DebugDescriptionParser.ParsedElement,
        in viewport: (x: Double, y: Double, w: Double, h: Double)
    ) -> Bool {
        let centerX = element.frame.x + element.frame.w / 2
        let centerY = element.frame.y + element.frame.h / 2
        return centerX >= viewport.x && centerX <= viewport.x + viewport.w
            && centerY >= viewport.y && centerY <= viewport.y + viewport.h
    }

    /// Splits rows already sorted top-to-bottom into maximal runs that share a left
    /// edge and a size and step down the screen by a constant pitch.
    ///
    /// Both the pitch and the shape are compared against the run's **first**
    /// members rather than the previous row: comparing neighbours lets the slack
    /// accumulate, so a stack whose spacing or width drifts a point per row — not a
    /// list at all — would pass the whole way down. The pitch is read off the run
    /// rather than tracked in a variable, so there is no second piece of state to
    /// keep in step with it.
    ///
    /// When a run breaks it is the *previous* row, not the current one, that starts
    /// the next candidate — as long as the two are still adjacent, i.e. the pitch
    /// broke and the shape did not. Restarting at the current row instead loses a
    /// row: one lone cell of the same height above a group (an ordinary one-row
    /// section, which iOS grouped tables are full of) pairs with the group's first
    /// row, that pair is discarded for being too short, and `@r1` then names the
    /// group's *second* row and taps it reporting success.
    private static func uniformRuns(in rows: [ListCluster.Row]) -> [[ListCluster.Row]] {
        var runs: [[ListCluster.Row]] = []
        var run: [ListCluster.Row] = []

        for row in rows {
            guard let previous = run.last else {
                run = [row]
                continue
            }
            if continues(run, with: row, after: previous) {
                run.append(row)
            } else if run.count >= minimumRows {
                runs.append(run)
                run = [row]
            } else if run.count >= 2, adjacent(previous, row) {
                run = [previous, row]
            } else {
                run = [row]
            }
        }
        if run.count >= minimumRows { runs.append(run) }
        return runs
    }

    /// Whether `row` could be the one directly below `previous` in some list: same
    /// left edge, same size, and stepping down the screen.
    private static func adjacent(_ previous: ListCluster.Row, _ row: ListCluster.Row) -> Bool {
        row.element.frame.y - previous.element.frame.y > tolerance
            && sameShape(row, previous)
    }

    private static func sameShape(_ a: ListCluster.Row, _ b: ListCluster.Row) -> Bool {
        close(a.element.frame.x, b.element.frame.x)
            && close(a.element.frame.w, b.element.frame.w)
            && close(a.element.frame.h, b.element.frame.h)
    }

    private static func continues(
        _ run: [ListCluster.Row],
        with row: ListCluster.Row,
        after previous: ListCluster.Row
    ) -> Bool {
        guard adjacent(previous, row), sameShape(row, run[0]) else { return false }
        guard run.count >= 2 else { return true }
        let gap = row.element.frame.y - previous.element.frame.y
        return close(gap, run[1].element.frame.y - run[0].element.frame.y)
    }

    private static func close(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= tolerance
    }
}
