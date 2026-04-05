import Foundation
import XCTest

final class AppManager: @unchecked Sendable {
    private var apps: [String: XCUIApplication] = [:]
    private(set) var currentBundleId: String?

    enum LaunchError: Error {
        case unsupportedPlatform(String)
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
        app.launch()
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
    func activate(bundleId: String) -> XCUIApplication {
        let app = self.app(for: bundleId)
        app.activate()
        currentBundleId = bundleId
        return app
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
