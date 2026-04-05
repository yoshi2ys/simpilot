import Foundation
import Network

final class HTTPServer {
    private let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.simpilot.httpserver", qos: .userInitiated)
    private let router: Router

    init(port: UInt16) {
        self.port = port
        self.router = Router()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fatalError("[simpilot] Invalid port: \(port)")
        }
        do {
            self.listener = try NWListener(using: params, on: nwPort)
        } catch {
            fatalError("[simpilot] Failed to create listener: \(error)")
        }
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[simpilot] HTTP server listening on port \(self.port)")
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
        receiveData(on: connection, accumulated: Data())
    }

    private func receiveData(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[simpilot] Receive error: \(error)")
                connection.cancel()
                return
            }

            var data = accumulated
            if let content = content {
                data.append(content)
            }

            // Try to parse the request
            if let request = HTTPParser.parse(data) {
                // Check if we have the full body
                let headerEnd = HTTPParser.findHeaderEnd(data)
                if let headerEnd = headerEnd {
                    let bodyReceived = data.count - headerEnd
                    let contentLength = Int(request.headers["Content-Length"] ?? request.headers["content-length"] ?? "0") ?? 0
                    if bodyReceived < contentLength {
                        // Need more data
                        self.receiveData(on: connection, accumulated: data)
                        return
                    }
                }

                let response = self.router.handle(request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if isComplete {
                connection.cancel()
            } else {
                // Need more data to form a complete request
                self.receiveData(on: connection, accumulated: data)
            }
        }
    }
}
