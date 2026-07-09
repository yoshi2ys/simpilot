import Foundation
import Network

final class HTTPServer {
    /// How long a connection may take to deliver a *complete* request before we
    /// drop it (slowloris guard). This bounds request receipt only — the timer
    /// is cancelled the instant a full request is parsed, so slow handlers
    /// (e.g. `wait --timeout 60`) are unaffected.
    private static let requestTimeout: TimeInterval = 30

    private let config: AgentConfig
    private let listener: NWListener
    /// Serial by construction (no `.concurrent` attribute). Every connection
    /// callback, the per-connection `RequestAccumulator` mutation, and the
    /// slowloris `deadline.cancel()` all run here, so they never race. Must stay
    /// serial — making it concurrent would unsynchronize the accumulator writes
    /// and the deadline-vs-completion cancel.
    private let queue = DispatchQueue(label: "com.simpilot.httpserver", qos: .userInitiated)
    private let router: Router

    init(config: AgentConfig) {
        self.config = config
        self.router = Router(config: config)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: config.port) else {
            fatalError("[simpilot] Invalid port: \(config.port)")
        }
        do {
            switch config.bind {
            case .loopback:
                // Pinning `requiredLocalEndpoint` binds the socket to 127.0.0.1
                // in the kernel, which `lsof` can confirm. `requiredInterfaceType
                // = .loopback` leaves a wildcard bind in place and only filters
                // at accept time, so it is not used here.
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
                self.listener = try NWListener(using: params)
            case .all:
                // `AgentConfig.resolve` guarantees a token accompanies this mode.
                self.listener = try NWListener(using: params, on: nwPort)
            }
        } catch {
            fatalError("[simpilot] Failed to create listener: \(error)")
        }
    }

    func start() {
        listener.stateUpdateHandler = { [config] state in
            switch state {
            case .ready:
                print("[simpilot] HTTP server listening on \(config.bind.rawValue) port \(config.port)"
                    + " (auth: \(config.token == nil ? "off" : "token"))")
            case .failed(let error):
                print("[simpilot] Listener failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Drop connections that don't deliver a complete request in time
        // (slowloris). Cancelled the instant a full request is parsed.
        let deadline = DispatchWorkItem {
            print("[simpilot] Connection timed out before a complete request")
            connection.cancel()
        }
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: deadline)
        receiveData(on: connection, accumulated: Data(), deadline: deadline, accumulator: HTTPParser.RequestAccumulator())
    }

    private func receiveData(
        on connection: NWConnection,
        accumulated: Data,
        deadline: DispatchWorkItem,
        accumulator: HTTPParser.RequestAccumulator
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[simpilot] Receive error: \(error)")
                deadline.cancel()
                connection.cancel()
                return
            }

            var data = accumulated
            if let content = content {
                data.append(content)
            }

            // The parser owns every size limit and emits the reject status; the
            // server only does I/O and enforces the receive deadline.
            switch HTTPParser.classify(data, into: accumulator) {
            case .complete(let request):
                // Cancel before the (possibly slow) handler runs so the receive
                // deadline can't fire mid-handling.
                deadline.cancel()
                // Authenticate at the socket boundary, beside the parser's own
                // `.reject` responses — not inside `Router`, whose `handleDirect`
                // would then have to be a documented unauthenticated exception.
                guard self.isAuthorized(request) else {
                    self.send(Self.unauthorizedResponse, on: connection)
                    return
                }
                self.send(self.router.handle(request), on: connection)
            case .reject(let status, let code, let message):
                deadline.cancel()
                self.send(HTTPResponseBuilder.error(message, code: code, status: status), on: connection)
            case .needMoreData:
                if isComplete {
                    deadline.cancel()
                    connection.cancel()
                } else {
                    self.receiveData(on: connection, accumulated: data, deadline: deadline, accumulator: accumulator)
                }
            }
        }
    }

    /// True when the agent has no token (loopback-only, nothing to guard) or the
    /// request carries the right one.
    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let token = config.token else { return true }
        return TokenAuth.matches(
            expected: token,
            provided: HTTPParser.headerValue(TokenAuth.headerName, in: request.headers)
        )
    }

    private static let unauthorizedResponse = HTTPResponseBuilder.error(
        "Missing or invalid \(TokenAuth.headerName) header",
        code: "unauthorized",
        status: 401
    )

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
