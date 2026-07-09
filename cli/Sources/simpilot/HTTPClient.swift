import Foundation

struct HTTPClient: Sendable {
    /// Header carrying the agent's shared secret. Must match the agent's
    /// `TokenAuth.headerName`.
    static let tokenHeader = "X-Simpilot-Token"

    let baseURL: String
    let timeout: TimeInterval
    /// Secret for the agent this client talks to, read from the registry. Nil
    /// for a loopback agent started without one (e.g. launched from Xcode).
    let token: String?

    init(baseURL: String, timeout: TimeInterval = 30, token: String? = nil) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.token = token
    }

    init(host: String, port: Int, timeout: TimeInterval = 30, token: String? = nil) {
        self.baseURL = "http://\(host.urlHost):\(port)"
        self.timeout = timeout
        self.token = token
    }

    /// Buffer added on top of a server-side operation budget to absorb network
    /// and processing latency, mirroring the scenario runner's per-step buffer.
    static let operationBuffer: TimeInterval = 5

    /// Per-call request timeout for an operation the agent may spend up to
    /// `budgetSeconds` working on. Never shorter than the client default, so
    /// quick calls are unaffected, but at least `budget + buffer` so a
    /// legitimate long op (e.g. `wait --timeout 60`) isn't aborted at the
    /// default 30s and misreported as `agent_unreachable` (A5). Returns nil for
    /// a nil budget so the caller falls back to the default timeout.
    func requestTimeout(forOperationBudget budgetSeconds: TimeInterval?) -> TimeInterval? {
        budgetSeconds.map { max(timeout, $0 + Self.operationBuffer) }
    }

    func get(_ path: String, timeout: TimeInterval? = nil) throws -> Data {
        var request = try makeRequest(path, timeout: timeout)
        request.httpMethod = "GET"
        return try perform(request)
    }

    func post(_ path: String, body: [String: Any], timeout: TimeInterval? = nil) throws -> Data {
        var request = try makeRequest(path, timeout: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try perform(request)
    }

    /// Internal rather than private so tests can assert the token header and
    /// URL construction without standing up an agent.
    func makeRequest(_ path: String, timeout: TimeInterval?) throws -> URLRequest {
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw CLIError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout ?? self.timeout
        if let token {
            request.setValue(token, forHTTPHeaderField: Self.tokenHeader)
        }
        return request
    }

    /// POST with a per-call timeout sized to the server-side operation budget
    /// (see `requestTimeout(forOperationBudget:)`). Collapses the budget→timeout
    /// plumbing every long-running command would otherwise repeat.
    func post(_ path: String, body: [String: Any], operationBudget: TimeInterval?) throws -> Data {
        try post(path, body: body, timeout: requestTimeout(forOperationBudget: operationBudget))
    }

    private func perform(_ request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var resultData: Data?
        nonisolated(unsafe) var resultError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            resultData = data
            resultError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = resultError {
            // A request timeout means the agent *is* reachable but the operation
            // outran the client deadline — a distinct failure from "can't
            // connect" that must not be reported (or exit) as agent_unreachable.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                throw CLIError.agentTimeout(baseURL, request.timeoutInterval)
            }
            // Everything else (connection refused, host not found, connection
            // lost, TLS failure) is the agent being unreachable.
            throw CLIError.agentUnreachable(baseURL)
        }

        guard let data = resultData else {
            throw CLIError.agentUnreachable(baseURL)
        }

        return data
    }
}

enum CLIError: Error {
    case agentUnreachable(String)
    case agentTimeout(String, TimeInterval)
    case invalidURL(String)
    case invalidArgs(String)
    case commandFailed(String)
}

extension String {
    /// Wraps IPv6 addresses in brackets for use in URLs per RFC 3986.
    var urlHost: String {
        guard contains(":"), !hasPrefix("[") else { return self }
        return "[\(self)]"
    }
}
