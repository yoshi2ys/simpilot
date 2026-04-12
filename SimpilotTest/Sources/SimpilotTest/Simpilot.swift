import Foundation

/// Entry point for the SimpilotTest DSL.
public enum Simpilot {
    /// Connect to a running simpilot agent and verify connectivity.
    public static func connect(
        host: String = "localhost",
        port: Int = 8222,
        timeout: TimeInterval = 30
    ) async throws -> SimpilotApp {
        let client = HTTPClient(host: host, port: port, timeout: timeout)
        let app = SimpilotApp(client: client)
        try await app.health()
        return app
    }

    /// Connect to a running simpilot agent and launch the given app.
    public static func launch(
        _ bundleId: String,
        host: String = "localhost",
        port: Int = 8222,
        timeout: TimeInterval = 30
    ) async throws -> SimpilotApp {
        let app = try await connect(host: host, port: port, timeout: timeout)
        try await app.launch(bundleId)
        return app
    }
}
