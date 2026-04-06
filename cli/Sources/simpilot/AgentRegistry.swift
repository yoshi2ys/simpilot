import Foundation

struct AgentRecord: Codable {
    let port: Int
    let pid: Int32
    let udid: String
    let device: String
    let isClone: Bool
    let startedAt: Date
}

enum AgentRegistry {

    private static var dirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".simpilot")
    }

    private static var fileURL: URL {
        dirURL.appendingPathComponent("agents.json")
    }

    // MARK: - CRUD

    static func load() -> [AgentRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder.withISO8601.decode([AgentRecord].self, from: data) else {
            return []
        }
        // Prune dead PIDs
        let alive = records.filter { kill($0.pid, 0) == 0 }
        if alive.count != records.count {
            save(alive)
        }
        return alive
    }

    static func save(_ records: [AgentRecord]) {
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.withISO8601.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func add(_ record: AgentRecord) {
        var records = load()
        records.append(record)
        save(records)
    }

    static func remove(port: Int) -> AgentRecord? {
        var records = load()
        guard let index = records.firstIndex(where: { $0.port == port }) else { return nil }
        let removed = records.remove(at: index)
        save(records)
        return removed
    }

    @discardableResult
    static func removeAll() -> [AgentRecord] {
        let records = load()
        save([])
        return records
    }

    // MARK: - Port File

    static func writePortFile(udid: String, port: Int) {
        try? String(port).write(toFile: portFilePath(udid), atomically: true, encoding: .utf8)
    }

    static func removePortFile(udid: String) {
        try? FileManager.default.removeItem(atPath: portFilePath(udid))
    }

    private static func portFilePath(_ udid: String) -> String {
        "/tmp/simpilot-port-\(udid)"
    }

    // MARK: - Port Assignment

    static func findAvailablePort(from base: Int = 8222) throws -> Int {
        let occupied = Set(load().map(\.port))
        var port = base
        while port < base + 100 {
            if !occupied.contains(port) && !isTCPPortInUse(port) {
                return port
            }
            port += 1
        }
        throw CLIError.commandFailed("No available port found in range \(base)-\(base + 99)")
    }

    private static func isTCPPortInUse(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                connect(sock, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        })
        return result == 0
    }
}

// MARK: - JSON Coding Helpers

private extension JSONDecoder {
    static let withISO8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let withISO8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
