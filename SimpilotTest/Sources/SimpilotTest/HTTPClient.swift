import Foundation

struct HTTPClient: Sendable {
    let baseURL: String
    let timeout: TimeInterval

    init(host: String, port: Int, timeout: TimeInterval = 30) {
        self.baseURL = "http://\(host.urlHost):\(port)"
        self.timeout = timeout
    }

    func get(_ path: String, timeout: TimeInterval? = nil) async throws -> Data {
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw SimpilotError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout ?? self.timeout
        return try await perform(request)
    }

    func post(_ path: String, body: [String: Any], timeout: TimeInterval? = nil) async throws -> Data {
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw SimpilotError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout ?? self.timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw classifyError(error)
        }
        return data
    }

    private func classifyError(_ error: Error) -> SimpilotError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain &&
            (nsError.code == NSURLErrorCannotConnectToHost ||
             nsError.code == NSURLErrorNetworkConnectionLost ||
             nsError.code == NSURLErrorCannotFindHost ||
             nsError.code == NSURLErrorTimedOut ||
             nsError.code == NSURLErrorSecureConnectionFailed) {
            return .agentUnreachable(baseURL)
        }
        // Connection refused: POSIX error 61
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 61 {
            return .agentUnreachable(baseURL)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSPOSIXErrorDomain && underlying.code == 61 {
                return .agentUnreachable(baseURL)
            }
        }
        return .agentUnreachable(baseURL)
    }
}

extension String {
    /// Wraps IPv6 addresses in brackets for use in URLs per RFC 3986.
    var urlHost: String {
        guard contains(":"), !hasPrefix("[") else { return self }
        return "[\(self)]"
    }
}
