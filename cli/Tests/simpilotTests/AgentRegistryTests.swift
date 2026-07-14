import XCTest
@testable import simpilot

/// Covers the parts of the registry that can be exercised without touching the
/// real `~/.simpilot` directory: port selection, record decoding, and the
/// PID-identity check that decides which records survive a prune.
final class AgentRegistryTests: XCTestCase {

    // MARK: - Port assignment

    func testFirstFreePortSkipsOccupiedAndListeningPorts() throws {
        let port = try AgentRegistry.firstFreePort(
            from: 8222,
            occupied: [8222, 8223],
            isInUse: { $0 == 8224 }
        )
        XCTAssertEqual(port, 8225)
    }

    func testFirstFreePortReturnsBaseWhenNothingIsTaken() throws {
        let port = try AgentRegistry.firstFreePort(from: 8222, occupied: [], isInUse: { _ in false })
        XCTAssertEqual(port, 8222)
    }

    func testFirstFreePortThrowsWhenRangeIsExhausted() {
        XCTAssertThrowsError(
            try AgentRegistry.firstFreePort(from: 8222, occupied: [], isInUse: { _ in true })
        ) { error in
            guard case CLIError.commandFailed(let message) = error else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("8222-8321"), message)
        }
    }

    func testFirstFreePortScansExactlyOneHundredPorts() throws {
        // 8222...8321 inclusive is the documented range; 8321 must be reachable.
        let port = try AgentRegistry.firstFreePort(
            from: 8222,
            occupied: Set(8222..<8321),
            isInUse: { _ in false }
        )
        XCTAssertEqual(port, 8321)
    }

    // MARK: - Record decoding (backwards compatibility)

    private func decode(_ json: String) throws -> AgentRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentRecord.self, from: Data(json.utf8))
    }

    func testLegacyRecordWithoutNewFieldsStillDecodes() throws {
        let record = try decode("""
        {"port":8222,"pid":123,"udid":"UD","device":"iPhone","isClone":false,
         "startedAt":"2026-07-08T00:00:00Z"}
        """)
        XCTAssertEqual(record.host, "127.0.0.1", "legacy records default to the loopback host")
        XCTAssertFalse(record.isPhysical)
        XCTAssertNil(record.pidStartTime)
        XCTAssertNil(record.token)
    }

    func testFullRecordRoundTrips() throws {
        let original = AgentRecord(
            port: 8223, pid: 456, udid: "UD-2", device: "iPhone Air", isClone: true,
            startedAt: Date(timeIntervalSince1970: 1_770_000_000),
            host: "dev.coredevice.local", isPhysical: true,
            pidStartTime: 1_769_999_000.25, token: "cafebabe"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try decode(String(decoding: try encoder.encode(original), as: UTF8.self))

        XCTAssertEqual(decoded.port, original.port)
        XCTAssertEqual(decoded.host, original.host)
        XCTAssertEqual(decoded.isPhysical, original.isPhysical)
        XCTAssertEqual(decoded.token, original.token)
        XCTAssertEqual(decoded.pidStartTime ?? 0, 1_769_999_000.25, accuracy: 0.0001,
                       "sub-second precision must survive JSON, or PID identity breaks")
    }

    func testBaseURLBracketsIPv6Hosts() {
        func record(host: String) -> AgentRecord {
            AgentRecord(port: 8222, pid: 1, udid: "", device: "", isClone: false,
                        startedAt: Date(), host: host)
        }
        XCTAssertEqual(record(host: "127.0.0.1").baseURL, "http://127.0.0.1:8222")
        XCTAssertEqual(record(host: "fd4d:85e2:eeb::1").baseURL, "http://[fd4d:85e2:eeb::1]:8222")
        XCTAssertEqual(record(host: "[fd4d::1]").baseURL, "http://[fd4d::1]:8222",
                       "an already-bracketed host must not be double-bracketed")
    }

    // MARK: - PID identity (dead-PID prune)

    func testCurrentProcessIsAliveAndHasAStartTime() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let started = try XCTUnwrap(ProcessIdentity.startTime(pid: pid))
        XCTAssertGreaterThan(started, 0)
        XCTAssertTrue(ProcessIdentity.isAlive(pid: pid, recordedStartTime: started))
    }

    func testStartTimeIsStableAcrossCalls() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = try XCTUnwrap(ProcessIdentity.startTime(pid: pid))
        let second = try XCTUnwrap(ProcessIdentity.startTime(pid: pid))
        XCTAssertTrue(ProcessIdentity.matches(first, second))
    }

    func testRecycledPIDIsNotAlive() {
        // Same PID, a start time that doesn't belong to it: the exact case a
        // bare `kill(pid, 0)` check would wave through.
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertFalse(ProcessIdentity.isAlive(pid: pid, recordedStartTime: 1.0))
    }

    func testLegacyRecordWithoutStartTimeFallsBackToExistence() {
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(ProcessIdentity.isAlive(pid: pid, recordedStartTime: nil))
    }

    func testVanishedPIDIsNotAlive() throws {
        // Reap a real child so its PID is certain to be gone, not merely unused.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        let pid = process.processIdentifier
        XCTAssertNil(ProcessIdentity.startTime(pid: pid))
        XCTAssertFalse(ProcessIdentity.isAlive(pid: pid, recordedStartTime: nil))
        XCTAssertFalse(ProcessIdentity.isAlive(pid: pid, recordedStartTime: 12345.0))
    }
}
