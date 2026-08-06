#if !os(Linux)
import Foundation
import XCTest
@testable import DiskInventoryZed

final class DuplicateVerifierTests: XCTestCase {
    func testVerifierRejectsSameSizedDifferentFilesAndConfirmsExactMatches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedDuplicateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first.bin")
        let secondURL = directory.appendingPathComponent("renamed-copy.bin")
        let differentURL = directory.appendingPathComponent("different.bin")
        try Data(repeating: 0xAB, count: 256_000).write(to: firstURL)
        try Data(repeating: 0xAB, count: 256_000).write(to: secondURL)
        try Data(repeating: 0xCD, count: 256_000).write(to: differentURL)

        let files = [firstURL, secondURL, differentURL].map { url in
            FileNode(
                url: url,
                name: url.lastPathComponent,
                kind: .file,
                logicalSize: 256_000,
                allocatedSize: 256_000
            )
        }
        let candidate = DuplicateCandidate(
            id: "256000",
            fileSize: 256_000,
            files: files
        )

        let result = try await DuplicateVerifier.verify(candidates: [candidate]) { _ in }

        XCTAssertTrue(result.unreadablePaths.isEmpty)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].files.map(\.path)), Set([firstURL.path, secondURL.path]))
        XCTAssertEqual(result.groups[0].potentialSavings, 256_000)
    }
}
#endif
