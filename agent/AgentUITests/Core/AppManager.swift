import Foundation
import XCTest

final class AppManager: @unchecked Sendable {
    private var apps: [String: XCUIApplication] = [:]
    private(set) var currentBundleId: String?

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
            apps[bundleId] = app
        }
        if let exceptionMsg = catchObjCException({ app.launch() }) {
            apps.removeValue(forKey: bundleId)
            throw LaunchError.launchFailed("Failed to launch \(bundleId): \(exceptionMsg)")
        }
        currentBundleId = bundleId
        return app
        #endif
    }

    /// Terminate an app by bundle ID.
    func terminate(bundleId: String) {
        if let app = apps[bundleId] {
            app.terminate()
        }
        if currentBundleId == bundleId {
            currentBundleId = nil
        }
    }

    /// Get the current foreground app. If none is tracked, returns a default XCUIApplication.
    func currentApp() -> XCUIApplication {
        if let bundleId = currentBundleId, let app = apps[bundleId] {
            return app
        }
        // Default: the app under test
        let app = XCUIApplication()
        return app
    }

    /// Bring an app to the foreground without relaunching.
    func activate(bundleId: String) throws -> XCUIApplication {
        let app = self.app(for: bundleId)
        if let exceptionMsg = catchObjCException({ app.activate() }) {
            throw LaunchError.activateFailed("Failed to activate \(bundleId): \(exceptionMsg)")
        }
        currentBundleId = bundleId
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
        apps[bundleId] = app
        return app
    }
}
