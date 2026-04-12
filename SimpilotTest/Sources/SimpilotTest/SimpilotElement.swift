import Foundation

/// Chainable element reference for fluent assertions and interactions.
public struct SimpilotElement: Sendable {
    let query: String
    let app: SimpilotApp

    /// Tap this element.
    public func tap(timeout: TimeInterval? = nil) async throws {
        try await app.tap(query, timeout: timeout)
    }

    /// Double-tap this element.
    public func doubleTap() async throws {
        try await app.doubleTap(query)
    }

    /// Long-press this element.
    public func longPress(duration: TimeInterval? = nil) async throws {
        try await app.longPress(query, duration: duration)
    }

    /// Type text into this element.
    public func type(_ text: String, method: String? = nil) async throws {
        try await app.type(text, into: query, method: method)
    }

    /// Assert this element exists.
    public func assertExists(timeout: TimeInterval? = nil) async throws {
        try await app.assertExists(query, timeout: timeout)
    }

    /// Assert this element does not exist.
    public func assertNotExists(timeout: TimeInterval? = nil) async throws {
        try await app.assertNotExists(query, timeout: timeout)
    }

    /// Assert this element's value matches the expected string.
    public func assertValue(_ expected: String, timeout: TimeInterval? = nil) async throws {
        try await app.assertValue(query, expected: expected, timeout: timeout)
    }

    /// Assert this element is enabled.
    public func assertEnabled(timeout: TimeInterval? = nil) async throws {
        try await app.assertEnabled(query, timeout: timeout)
    }

    /// Assert this element is hittable.
    public func assertHittable(timeout: TimeInterval? = nil) async throws {
        try await app.assertHittable(query, timeout: timeout)
    }

    /// Take a screenshot of this element.
    public func screenshot(file: String? = nil) async throws -> SimpilotScreenshot {
        try await app.screenshot(file: file, element: query)
    }
}
