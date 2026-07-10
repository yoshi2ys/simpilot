import Foundation
import XCTest
@testable import simpilot

/// The registry directory holds agent tokens, so it must be owner-only (0700).
/// `createDirectory` leaves it at the umask default (0755) unless told otherwise,
/// which — on a multi-user machine — lets another local user traverse in and read
/// `agents.json` during the brief window a fresh atomic write leaves it at 0644.
///
/// A directory this process *creates* is made 0700 via `createDirectory`'s
/// attributes (safe — we own it). Re-tightening a *pre-existing* directory is
/// scoped to the default `~/.simpilot`, so a `SIMPILOT_HOME` pointed at a shared
/// dir is never chmod'd destructively; that guard is pinned here too.
///
/// The default-path migration (an existing `~/.simpilot` at 0755 → 0700) cannot
/// be exercised hermetically — it is the one path `SIMPILOT_HOME` can't stand in
/// for — and was verified live instead.
final class AgentRegistryPermissionsTests: XCTestCase {

    private var created: [URL] = []

    override func tearDownWithError() throws {
        unsetenv("SIMPILOT_HOME")
        for url in created { try? FileManager.default.removeItem(at: url) }
        created = []
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func aliveRecord() -> AgentRecord {
        let pid = ProcessInfo.processInfo.processIdentifier
        return AgentRecord(
            port: 8222, pid: pid, udid: "UDID", device: "iPhone",
            isClone: false, startedAt: Date(),
            pidStartTime: ProcessIdentity.startTime(pid: pid), token: "secret"
        )
    }

    func testFreshRegistryDirectoryIsCreatedOwnerOnly() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("simpilot-perms-fresh-\(getpid())-\(UUID().uuidString)")
        created.append(dir)
        setenv("SIMPILOT_HOME", dir.path, 1)

        try AgentRegistry.add(aliveRecord())

        XCTAssertEqual(try mode(of: dir), 0o700, "a fresh registry dir must be 0700, not the umask default")
    }

    /// The footgun guard: a pre-existing directory reached via `SIMPILOT_HOME`
    /// must NOT be chmod'd — the caller may have pointed it at a shared location
    /// (`/tmp`, `$HOME`), and silently tightening that would be destructive.
    func testPreExistingSIMPILOT_HOMEDirectoryIsNotChmoddedFromUnderTheCaller() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("simpilot-perms-shared-\(getpid())-\(UUID().uuidString)")
        created.append(dir)
        // Stands in for a shared dir the caller pointed SIMPILOT_HOME at.
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        setenv("SIMPILOT_HOME", dir.path, 1)

        try AgentRegistry.add(aliveRecord())

        XCTAssertEqual(try mode(of: dir), 0o755, "a pre-existing SIMPILOT_HOME dir must be left as the caller set it")
    }
}
