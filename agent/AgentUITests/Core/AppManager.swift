import Foundation
import XCTest

final class AppManager: @unchecked Sendable {
    private var apps: [String: XCUIApplication] = [:]
    private(set) var currentBundleId: String?

    /// The `@eN` pairing from the last `elements --format outline` (SU3).
    ///
    /// It lives here rather than in a store of its own because every handler that
    /// resolves a query already holds the `AppManager`, and because the staleness
    /// rule is about the app: `currentBundleId` is the other half of the check.
    /// Only the latest snapshot is kept — an alias names "the list I just read",
    /// and keeping older ones would let a caller resolve against a screen two
    /// navigations ago.
    private(set) var snapshot: ElementSnapshot?

    func recordSnapshot(_ snapshot: ElementSnapshot) {
        self.snapshot = snapshot
    }

    /// The one place the foreground app changes.
    ///
    /// Bringing an app forward replaces the whole screen, so any tree cached for
    /// the previous one is dropped here (SU5). This is the app-switching
    /// counterpart to `AXTree.settle`, and it is a single funnel rather than three
    /// call sites because two of the routes that reach it are `mutates: false`:
    /// `GET /elements?bundleId=` and `GET /source?bundleId=` activate an app and
    /// then read the tree back *within* the command, so the batch-level
    /// invalidation is both too late and — correctly — not asked for. `AXTreeTests`
    /// fails if `currentBundleId` is ever assigned anywhere but here.
    ///
    /// It drops the tree even when the bundle ID is unchanged: re-activating the
    /// app already in front is exactly how a caller returns from a system sheet or
    /// another app, and the screen after that is not the screen before it.
    private func enterForeground(_ bundleId: String?) {
        currentBundleId = bundleId
        AXTree.invalidate()
    }

    enum LaunchError: Error {
        case unsupportedPlatform(String)
        case launchFailed(String)
        case activateFailed(String)
    }

    /// Launch an app by bundle ID. Returns the XCUIApplication instance.
    func launch(bundleId: String) throws -> XCUIApplication {
        #if os(tvOS) || os(watchOS)
        throw LaunchError.unsupportedPlatform("External app launch is not supported on this platform. Use the host app.")
        #else
        let app: XCUIApplication
        if let existing = apps[bundleId] {
            app = existing
        } else {
            app = XCUIApplication(bundleIdentifier: bundleId)
            disableQuiescenceWait(app)
            apps[bundleId] = app
        }
        if let exceptionMsg = catchObjCException({ app.launch() }) {
            apps.removeValue(forKey: bundleId)
            throw LaunchError.launchFailed("Failed to launch \(bundleId): \(exceptionMsg)")
        }
        enterForeground(bundleId)
        return app
        #endif
    }

    /// Terminate an app by bundle ID.
    func terminate(bundleId: String) {
        if let app = apps[bundleId] {
            app.terminate()
        }
        if currentBundleId == bundleId {
            enterForeground(nil)
        }
    }

    /// Get the current foreground app. If none is tracked, returns a default XCUIApplication.
    func currentApp() -> XCUIApplication {
        if let bundleId = currentBundleId, let app = apps[bundleId] {
            return app
        }
        return defaultApp
    }

    private lazy var defaultApp: XCUIApplication = {
        let app = XCUIApplication()
        disableQuiescenceWait(app)
        return app
    }()

    /// Bring an app to the foreground without relaunching.
    func activate(bundleId: String) throws -> XCUIApplication {
        let app = self.app(for: bundleId)
        if let exceptionMsg = catchObjCException({ app.activate() }) {
            throw LaunchError.activateFailed("Failed to activate \(bundleId): \(exceptionMsg)")
        }
        enterForeground(bundleId)
        return app
    }

    /// Resolve an app by optional bundle ID: activate if provided, otherwise return current app.
    func resolveApp(bundleId: String?) throws -> XCUIApplication {
        if let bundleId = bundleId, !bundleId.isEmpty {
            return try activate(bundleId: bundleId)
        }
        return currentApp()
    }

    /// Get or create an app for a specific bundle ID without launching.
    func app(for bundleId: String) -> XCUIApplication {
        if let existing = apps[bundleId] {
            return existing
        }
        let app = XCUIApplication(bundleIdentifier: bundleId)
        disableQuiescenceWait(app)
        apps[bundleId] = app
        return app
    }
}
