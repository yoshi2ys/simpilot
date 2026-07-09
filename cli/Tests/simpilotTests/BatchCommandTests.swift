import XCTest
@testable import simpilot

/// Coverage for `BatchCommand.readStdin` (A30).
///
/// The bug: `FileHandle.standardInput.availableData` only returns the first
/// chunk available (typically <=64KB, sometimes less), silently truncating
/// large batch JSON piped in. `readStdin` uses `readDataToEndOfFile()` instead.
final class BatchCommandTests: XCTestCase {

    /// Backs a FileHandle with a temp file (not a Pipe) so writing a large
    /// payload can't deadlock against the kernel's pipe buffer limit.
    private func handle(for string: String) -> FileHandle {
        let path = NSTemporaryDirectory() + "batch-stdin-test-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: path, contents: string.data(using: .utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return FileHandle(forReadingAtPath: path)!
    }

    func test_readStdin_readsFullLargeInput() {
        let large = String(repeating: "a", count: 200_000)
        let json = #"{"commands":[{"method":"GET","path":"/\#(large)"}]}"#
        XCTAssertEqual(BatchCommand.readStdin(from: handle(for: json)), json)
    }

    func test_readStdin_trimsSurroundingWhitespace() {
        XCTAssertEqual(BatchCommand.readStdin(from: handle(for: "  {\"a\":1}  \n")), "{\"a\":1}")
    }

    func test_readStdin_emptyInput_returnsNil() {
        XCTAssertNil(BatchCommand.readStdin(from: handle(for: "")))
    }
}
