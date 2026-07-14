import Foundation
import XCTest
@testable import simpilot

/// A9: concurrent `simpilot` processes each did load → modify → save with no
/// lock, so the last save dropped the other's record. `flock` on a sidecar file
/// makes the whole cycle exclusive.
///
/// These tests point `SIMPILOT_HOME` at a temp directory — they never touch the
/// developer's real `~/.simpilot`. `flock` is per open-file-description, so two
/// `open()` calls from different threads of one process contend exactly as two
/// processes would.
final class AgentRegistryConcurrencyTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("simpilot-registry-tests-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SIMPILOT_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("SIMPILOT_HOME")
        try? FileManager.default.removeItem(at: home)
    }

    /// Records must look alive or `load()` prunes them, so pin them to this
    /// process, whose start time is real.
    private func record(port: Int) -> AgentRecord {
        let pid = ProcessInfo.processInfo.processIdentifier
        return AgentRecord(
            port: port, pid: pid, udid: "UDID-\(port)", device: "iPhone",
            isClone: false, startedAt: Date(),
            pidStartTime: ProcessIdentity.startTime(pid: pid), token: "t-\(port)"
        )
    }

    func testConcurrentAddsDoNotLoseRecords() throws {
        let count = 24
        DispatchQueue.concurrentPerform(iterations: count) { index in
            try? AgentRegistry.add(self.record(port: 9000 + index))
        }

        let records = try AgentRegistry.load()
        XCTAssertEqual(
            records.count, count,
            "a lost update means one process's agent is unstoppable"
        )
        XCTAssertEqual(Set(records.map(\.port)).count, count, "no port recorded twice")
    }

    func testConcurrentAddsAndRemovesConverge() throws {
        for index in 0..<12 {
            try AgentRegistry.add(record(port: 9100 + index))
        }

        // Remove the even ports while adding a fresh batch, all at once.
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            if index.isMultiple(of: 2) {
                _ = try? AgentRegistry.remove(port: 9100 + index)
            } else {
                try? AgentRegistry.add(self.record(port: 9200 + index))
            }
        }

        let ports = Set(try AgentRegistry.load().map(\.port))
        let survivingOdd = Set((0..<12).filter { !$0.isMultiple(of: 2) }.map { 9100 + $0 })
        let added = Set((0..<12).filter { !$0.isMultiple(of: 2) }.map { 9200 + $0 })
        XCTAssertEqual(ports, survivingOdd.union(added))
    }

    func testFindAvailablePortSkipsClaimedPorts() throws {
        try AgentRegistry.add(record(port: 9300))
        try AgentRegistry.add(record(port: 9301))
        XCTAssertEqual(try AgentRegistry.findAvailablePort(from: 9300), 9302)
    }

    /// The documented race: `findAvailablePort` cannot hold the lock across the
    /// minute-long `xcodebuild` launch, so concurrent cold `start`s *can* be
    /// handed the same port. What must never happen is two records for it —
    /// `stop --port` and `Simpilot.main` both assume the port is unique. The
    /// loser fails at `add`, loudly.
    func testDuplicatePortIsRejectedSoOnlyOneAgentOwnsIt() throws {
        let claims = 8
        let lock = NSLock()
        var succeeded = 0
        var failures: [Error] = []

        DispatchQueue.concurrentPerform(iterations: claims) { _ in
            let port = (try? AgentRegistry.findAvailablePort(from: 9400)) ?? -1
            do {
                try AgentRegistry.add(self.record(port: port))
                lock.lock(); succeeded += 1; lock.unlock()
            } catch {
                lock.lock(); failures.append(error); lock.unlock()
            }
        }

        let records = try AgentRegistry.load()
        XCTAssertEqual(records.count, Set(records.map(\.port)).count, "no port recorded twice")
        XCTAssertGreaterThanOrEqual(succeeded, 1)
        XCTAssertEqual(succeeded + failures.count, claims, "every claim resolved one way or the other")
        for error in failures {
            guard case CLIError.commandFailed(let message) = error else {
                return XCTFail("the loser must fail loudly, got \(error)")
            }
            XCTAssertTrue(message.contains("already claimed"), message)
        }
    }

    func testRegistryFileIsOwnerReadableOnly() throws {
        try AgentRegistry.add(record(port: 9400))
        let path = home.appendingPathComponent("agents.json").path
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600, "the registry holds agent tokens")
    }

    func testRemoveAllReturnsDeadRecordsToo() throws {
        try AgentRegistry.add(record(port: 9500))
        // A record whose process is long gone: `stop --all` still has to
        // terminate its runner and delete its clone.
        try AgentRegistry.add(AgentRecord(
            port: 9501, pid: 999_999, udid: "DEAD", device: "iPhone",
            isClone: true, startedAt: Date(), pidStartTime: 12345.0
        ))

        XCTAssertEqual(try AgentRegistry.load().count, 1, "load() prunes the dead one")
        XCTAssertEqual(try AgentRegistry.allRecords().count, 2, "allRecords() keeps it")

        let removed = try AgentRegistry.removeAll()
        XCTAssertEqual(Set(removed.map(\.port)), [9500, 9501], "stop --all must see the dead clone")
        XCTAssertTrue(try AgentRegistry.allRecords().isEmpty)
    }

    func testCorruptRegistryThrowsInsteadOfReadingAsEmpty() throws {
        try Data("{ not json".utf8).write(to: home.appendingPathComponent("agents.json"))
        XCTAssertThrowsError(try AgentRegistry.load()) { error in
            guard case CLIError.commandFailed(let message) = error else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("unreadable"), message)
        }
    }

    func testAbsentRegistryIsEmptyNotAnError() throws {
        XCTAssertTrue(try AgentRegistry.load().isEmpty)
        XCTAssertTrue(try AgentRegistry.allRecords().isEmpty)
    }
}
