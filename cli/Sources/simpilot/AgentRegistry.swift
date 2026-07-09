import Foundation

struct AgentRecord: Codable {
    let port: Int
    let pid: Int32
    let udid: String
    let device: String
    let isClone: Bool
    let startedAt: Date
    let host: String
    let isPhysical: Bool
    /// Kernel start time of `pid`, used to detect PID reuse. Nil in records
    /// written before start-time tracking existed.
    let pidStartTime: Double?
    /// Shared secret this agent requires in `X-Simpilot-Token`. Nil for a
    /// loopback agent started without one.
    let token: String?

    init(port: Int, pid: Int32, udid: String, device: String, isClone: Bool, startedAt: Date,
         host: String = "127.0.0.1", isPhysical: Bool = false,
         pidStartTime: Double? = nil, token: String? = nil) {
        self.port = port
        self.pid = pid
        self.udid = udid
        self.device = device
        self.isClone = isClone
        self.startedAt = startedAt
        self.host = host
        self.isPhysical = isPhysical
        self.pidStartTime = pidStartTime
        self.token = token
    }

    /// Base URL for HTTP requests to this agent.
    var baseURL: String { "http://\(host.urlHost):\(port)" }

    /// Whether `pid` still names this exact agent process (not a recycled PID).
    var isAlive: Bool {
        ProcessIdentity.isAlive(pid: pid, recordedStartTime: pidStartTime)
    }

    // Backwards-compatible decoding: fields added over time may be missing in
    // records written by an older simpilot.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decode(Int.self, forKey: .port)
        pid = try c.decode(Int32.self, forKey: .pid)
        udid = try c.decode(String.self, forKey: .udid)
        device = try c.decode(String.self, forKey: .device)
        isClone = try c.decode(Bool.self, forKey: .isClone)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        isPhysical = try c.decodeIfPresent(Bool.self, forKey: .isPhysical) ?? false
        pidStartTime = try c.decodeIfPresent(Double.self, forKey: .pidStartTime)
        token = try c.decodeIfPresent(String.self, forKey: .token)
    }
}

enum AgentRegistry {

    private static var dirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".simpilot")
    }

    private static var fileURL: URL {
        dirURL.appendingPathComponent("agents.json")
    }

    private static var lockURL: URL {
        dirURL.appendingPathComponent("registry.lock")
    }

    // MARK: - Locking

    /// Serialize read-modify-write cycles across concurrent `simpilot` processes.
    ///
    /// Without this, two `simpilot start` runs can both read the registry, both
    /// pick the same free port, and the second `save` drops the first agent's
    /// record. `flock` on a sidecar file (never the registry itself, which is
    /// replaced atomically and would take the lock with it) makes the whole
    /// load→mutate→save cycle exclusive.
    private static func withLock<T>(_ body: () throws -> T) throws -> T {
        try createDirectory()
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CLIError.commandFailed(
                "Failed to open registry lock at \(lockURL.path): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CLIError.commandFailed(
                "Failed to lock agent registry: \(String(cString: strerror(errno)))"
            )
        }
        defer { flock(descriptor, LOCK_UN) }

        return try body()
    }

    private static func createDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            throw CLIError.commandFailed(
                "Failed to create \(dirURL.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - CRUD

    /// Registry snapshot with dead records filtered out.
    ///
    /// Reads never write: no lock, no save. Persisting the prune here would mean
    /// a read-only `~/.simpilot` or an unopenable lock had to be swallowed, and
    /// `simpilot list` would print "no agents" while one was running — exactly
    /// the silent failure A28 removed from the write path. The next `mutate`
    /// re-prunes under the lock and persists it. Writes are atomic, so an
    /// unlocked read never observes a torn file.
    ///
    /// Throws when the registry exists but cannot be read. An absent registry is
    /// not a failure — it means no agent has ever started — but a corrupt one
    /// must not read as "no agents running", or `stop --port 8222` reports
    /// `success: true` for an agent that is very much alive and now unstoppable.
    static func load() throws -> [AgentRecord] {
        try loadUnlocked().filter(\.isAlive)
    }

    /// Every record, including ones whose `xcodebuild` has died.
    ///
    /// `stop` must use this. A dead `xcodebuild` is precisely the state where
    /// the simulator-side runner is still holding the port (it is parented by
    /// `launchd_sim`, not by `xcodebuild`), and where a `--clone` device still
    /// needs deleting. Filtering those records out would make `stop` answer
    /// "already stopped" for the one case its teardown exists to handle.
    static func allRecords() throws -> [AgentRecord] {
        try loadUnlocked()
    }

    /// Load, prune, hand the survivors to `body`, and persist whatever it
    /// returns — all under one exclusive lock. The trailing `saveUnlocked` is
    /// the only write: it persists the prune and the mutation together.
    @discardableResult
    private static func mutate<T>(_ body: (inout [AgentRecord]) -> T) throws -> T {
        try withLock {
            var records = try loadUnlocked().filter(\.isAlive)
            let result = body(&records)
            try saveUnlocked(records)
            return result
        }
    }

    /// An absent registry means no agent has ever started — an empty list, not a
    /// failure. Anything else (unreadable file, malformed JSON) is surfaced:
    /// silently returning `[]` would make every caller believe no agents exist.
    private static func loadUnlocked() throws -> [AgentRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try JSONDecoder.withISO8601.decode([AgentRecord].self, from: Data(contentsOf: fileURL))
        } catch {
            throw CLIError.commandFailed(
                "Agent registry at \(fileURL.path) is unreadable (\(error.localizedDescription)) "
                + "— delete it to reset, then re-run `simpilot start`"
            )
        }
    }

    /// Persist `records`. Failures throw rather than being swallowed: a command
    /// that reports `success: true` after failing to record its agent leaves the
    /// caller unable to `stop` it.
    private static func saveUnlocked(_ records: [AgentRecord]) throws {
        try createDirectory()
        do {
            let data = try JSONEncoder.withISO8601.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw CLIError.commandFailed(
                "Failed to write agent registry at \(fileURL.path): \(error.localizedDescription)"
            )
        }
        // `.atomic` writes land via a temp file whose mode ignores the original,
        // so the token-bearing registry is re-restricted on every save.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func add(_ record: AgentRecord) throws {
        try mutate { $0.append(record) }
    }

    static func remove(port: Int) throws -> AgentRecord? {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.port == port }) else { return nil }
            return records.remove(at: index)
        }
    }

    static func remove(udid: String) throws -> AgentRecord? {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.udid == udid }) else { return nil }
            return records.remove(at: index)
        }
    }

    /// Clear the registry and return **every** record it held, dead ones
    /// included — `stop --all` still has to terminate their runners and delete
    /// their clones. Going through `mutate` would prune them first, silently
    /// leaking a cloned simulator per crashed agent.
    @discardableResult
    static func removeAll() throws -> [AgentRecord] {
        try withLock {
            let snapshot = try loadUnlocked()
            try saveUnlocked([])
            return snapshot
        }
    }

    // MARK: - Port Assignment

    /// Lowest port not claimed by a live record and not already listening.
    ///
    /// The lock makes the scan consistent, but it cannot span the minute-long
    /// `xcodebuild` launch that follows, so two `simpilot start` processes
    /// racing from a cold registry can still choose the same port. The loser
    /// fails loudly when its agent cannot bind, rather than silently attaching
    /// to the winner's agent.
    static func findAvailablePort(from base: Int = 8222) throws -> Int {
        try withLock {
            let occupied = Set(try loadUnlocked().filter(\.isAlive).map(\.port))
            return try firstFreePort(from: base, occupied: occupied)
        }
    }

    /// Pure port search, hoisted so tests can drive it without the filesystem.
    static func firstFreePort(
        from base: Int,
        occupied: Set<Int>,
        isInUse: (Int) -> Bool = isTCPPortInUse
    ) throws -> Int {
        for port in base..<(base + 100) where !occupied.contains(port) && !isInUse(port) {
            return port
        }
        throw CLIError.commandFailed("No available port found in range \(base)-\(base + 99)")
    }

    static func isTCPPortInUse(_ port: Int) -> Bool {
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
