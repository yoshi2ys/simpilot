import Foundation

struct HTTPClient: Sendable {
    let baseURL: String
    let timeout: TimeInterval

    init(baseURL: String, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    init(host: String, port: Int, timeout: TimeInterval = 30) {
        self.baseURL = "http://\(host.urlHost):\(port)"
        self.timeout = timeout
    }

    func get(_ path: String, timeout: TimeInterval? = nil) throws -> Data {
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw CLIError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout ?? self.timeout
        return try perform(request)
    }

    func post(_ path: String, body: [String: Any], timeout: TimeInterval? = nil) throws -> Data {
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw CLIError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout ?? self.timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try perform(request)
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
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain &&
                (nsError.code == NSURLErrorCannotConnectToHost ||
                 nsError.code == NSURLErrorNetworkConnectionLost ||
                 nsError.code == NSURLErrorCannotFindHost ||
                 nsError.code == NSURLErrorTimedOut ||
                 nsError.code == NSURLErrorSecureConnectionFailed) {
                throw CLIError.agentUnreachable(baseURL)
            }
            // Connection refused shows up as POSIX error 61
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == 61 {
                throw CLIError.agentUnreachable(baseURL)
            }
            // Check underlying error for connection refused
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                if underlying.domain == NSPOSIXErrorDomain && underlying.code == 61 {
                    throw CLIError.agentUnreachable(baseURL)
                }
            }
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
