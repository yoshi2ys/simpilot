import Foundation
import XCTest

final class TypeHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let text = json["text"] as? String else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'text' in request body",
                code: "invalid_request"
            )
        }

        let query = json["query"] as? String
        let method = json["method"] as? String ?? "auto"
        let app = appManager.currentApp()

        let resolution = Self.resolveAndType(
            query: query,
            text: text,
            method: method,
            wait: TapHandler.parseWaitArgs(from: json),
            in: app,
            snapshot: appManager.snapshot,
            currentBundleId: appManager.currentBundleId
        )
        switch resolution {
        case .failure(let failure):
            return Self.failureResponse(for: failure)
        case .success(let usedMethod, let element):
            var responseData: [String: Any] = ["text": text, "action": "type", "method": usedMethod]
            if let query { responseData["query"] = query }
            if let element { responseData["element"] = element }
            return HTTPResponseBuilder.json(responseData)
        }
    }

    // MARK: - Shared resolution path

    /// Why `resolveAndType` could not type the text. Split out from
    /// `TypeResolution` so `failureResponse` takes only failures and can return
    /// a non-optional `Data` — neither call site needs a force-unwrap or an
    /// unreachable branch to translate one.
    enum TypeFailure {
        case waitTimeout(query: String, failedPredicates: [String], lastState: [String: Any]?, timeoutMs: Int)
        case elementNotFound(query: String)
        /// An `@eN` alias that no longer names an element on this screen.
        case aliasFailed(AliasResolutionError)
        /// An `@eN` alias combined with a wait — unsupported, not stale.
        case aliasNotPollable
        /// An `@eN` alias on a platform with no coordinate path (tvOS).
        case aliasNotSupportedOnPlatform
        /// PasteHelper already returns a full error envelope.
        case inputFailed(Data)
    }

    /// Outcome of `resolveAndType`. `/type` and `/action type` are the same
    /// feature and must not drift: both go through `resolveAndType` and
    /// translate failures with `failureResponse`. They differ only in how the
    /// success envelope is nested.
    enum TypeResolution {
        case success(usedMethod: String, element: [String: Any]?)
        case failure(TypeFailure)
    }

    /// Focus `query` (when given), then push `text` into it.
    ///
    /// Resolution mirrors `TapHandler.resolveAndTap`: wait gate first, then the
    /// debugDescription fast path, then `ElementResolver` as a fallback — both
    /// when a coordinate tap raises an ObjC exception (visionOS spatial windows)
    /// and when the parser misses a typed query (`searchField:Search`), whose
    /// element may exist under a type the text tree names differently. A parser
    /// miss on a bare label or `#identifier` is authoritative.
    ///
    /// Unlike tap, the focus tap aims at the element center: `TapHandler.tapPoint`
    /// offsets to the trailing edge for switches, which is the wrong end of a
    /// text field.
    static func resolveAndType(
        query: String?,
        text: String,
        method: String,
        wait: TapHandler.WaitArgs,
        in app: XCUIApplication,
        snapshot: ElementSnapshot?,
        currentBundleId: String?
    ) -> TypeResolution {
        #if !os(tvOS)
        var targetCoord: XCUICoordinate?
        #endif
        var element: [String: Any]?

        if let query, !query.isEmpty {
            // Mirrors `resolveAndTap`: on tvOS the focus tap below is compiled
            // out, so an alias has no coordinate to land on and would reach
            // `ElementResolver` as the literal label `@e1`.
            if AliasResolver.isAlias(query), !AliasResolver.isSupportedOnThisPlatform {
                return .failure(.aliasNotSupportedOnPlatform)
            }

            // When the poller ran, it already parsed the tree to satisfy the
            // predicates. Reuse what it found rather than paying a second
            // debugDescription IPC that could disagree with it.
            var polled: DebugDescriptionParser.FoundElement?
            switch TapHandler.awaitPredicates(query: query, wait: wait, in: app) {
            case .timedOut(let lastState, let failed):
                return .failure(.waitTimeout(
                    query: query,
                    failedPredicates: failed,
                    lastState: lastState,
                    timeoutMs: wait.timeoutMs
                ))
            case .satisfied(let found):
                polled = found
            case .aliasRejected:
                return .failure(.aliasNotPollable)
            case .notNeeded:
                break
            }

            #if os(tvOS)
            guard let resolved = try? ElementResolver.resolve(query: query, in: app) else {
                return .failure(.elementNotFound(query: query))
            }
            XCUIRemote.shared.press(.select)
            element = ElementResolver.describe(resolved)
            #else
            // `targetCoord` is where PasteHelper long-presses to summon the edit
            // menu. It must always name the *element*: a nil coord makes
            // PasteHelper fall back to the centre of the screen, so a
            // `--method paste` type would pop the menu over whatever happens to
            // sit there. Every branch below therefore sets it.
            let resolved: DebugDescriptionParser.FoundElement?
            if let polled {
                resolved = polled
            } else {
                switch DebugDescriptionParser.resolve(
                    query: query, in: app,
                    snapshot: snapshot, currentBundleId: currentBundleId
                ) {
                case .aliasFailed(let error): return .failure(.aliasFailed(error))
                case .found(let found): resolved = found
                case .notFound: resolved = nil
                }
            }
            if let found = resolved {
                let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                    .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
                element = found.asDict
                if catchObjCException({ coord.tap() }) == nil {
                    targetCoord = coord
                } else {
                    if AliasResolver.isAlias(query) {
                        return .failure(.aliasFailed(
                            .stale("\(query) resolved, but the focus tap could not be performed at its coordinate")
                        ))
                    }
                    // The coordinate itself is unusable (visionOS spatial
                    // windows) — handing it to PasteHelper would raise a second
                    // NSException. Re-target through the resolved element.
                    guard let resolved = try? ElementResolver.resolve(query: query, in: app) else {
                        return .failure(.elementNotFound(query: query))
                    }
                    resolved.tap()
                    targetCoord = resolved.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                }
            } else if query.trimmingCharacters(in: .whitespaces).contains(":") {
                guard let resolved = try? ElementResolver.resolve(query: query, in: app) else {
                    return .failure(.elementNotFound(query: query))
                }
                resolved.tap()
                targetCoord = resolved.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                element = ElementResolver.describe(resolved)
            } else {
                return .failure(.elementNotFound(query: query))
            }
            #endif
        }

        #if os(tvOS)
        let (usedMethod, inputError) = PasteHelper.performTextInput(text, method: method, at: nil, in: app)
        #else
        let (usedMethod, inputError) = PasteHelper.performTextInput(text, method: method, at: targetCoord, in: app)
        #endif
        if let inputError { return .failure(.inputFailed(inputError)) }

        return .success(usedMethod: usedMethod, element: element)
    }

    /// Shared error envelope for every `TypeFailure`, so `/type` and
    /// `/action type` cannot drift on wording or status codes.
    static func failureResponse(for failure: TypeFailure) -> Data {
        switch failure {
        case .waitTimeout(let query, let failed, let lastState, let timeoutMs):
            return TapHandler.waitTimeoutResponse(
                query: query,
                failedPredicates: failed,
                lastState: lastState,
                timeoutMs: timeoutMs
            )
        case .elementNotFound(let query):
            return HTTPResponseBuilder.error(
                ElementResolver.notFoundMessage(query: query),
                code: "element_not_found"
            )
        case .aliasFailed(let error):
            return AliasResponse.error(error)
        case .aliasNotPollable:
            return AliasResponse.unsupported("type with a wait", reason: .cannotBePolled)
        case .aliasNotSupportedOnPlatform:
            return AliasResponse.unsupported("type on this platform", reason: .notCoordinateDriven)
        case .inputFailed(let data):
            return data
        }
    }
}
