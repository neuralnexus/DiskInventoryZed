import Foundation
import XCTest
@testable import DiskInventoryZed

final class DiskScannerTests: XCTestCase {
    func testScanBuildsCompleteImmutableTree() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4_096).write(to: root.appendingPathComponent("root.bin"))
        try Data(repeating: 0xCD, count: 8_192).write(to: nested.appendingPathComponent("nested.bin"))

        let result = try await DiskScanner().scan(
            url: root,
            options: ScanOptions(
                skipDeveloperFolders: false,
                showHiddenFiles: true,
                showPackageContents: true,
                followSymlinks: false
            )
        ) { _ in }

        XCTAssertEqual(result.totalFiles, 2)
        XCTAssertEqual(result.totalDirectories, 2)
        XCTAssertEqual(result.root.children.count, 2)
        XCTAssertNotNil(result.root.findChild(at: nested.appendingPathComponent("nested.bin")))
        XCTAssertGreaterThanOrEqual(result.root.logicalSize, 12_288)
        XCTAssertGreaterThan(result.root.allocatedSize, 0)
    }

    func testHardLinksAreNotDoubleCountedOnDisk() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("original.bin")
        let linked = root.appendingPathComponent("linked.bin")
        try Data(repeating: 0xEF, count: 16_384).write(to: original)
        try FileManager.default.linkItem(at: original, to: linked)

        let result = try await DiskScanner().scan(
            url: root,
            options: ScanOptions(
                skipDeveloperFolders: false,
                showHiddenFiles: true,
                showPackageContents: true,
                followSymlinks: false
            )
        ) { _ in }

        let files = result.root.children.filter { !$0.isDirectory }
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.filter(\.isHardLinkDuplicate).count, 1)
        XCTAssertEqual(result.diagnostics.duplicateHardLinks, 1)
        XCTAssertEqual(result.root.allocatedSize, files.map(\.allocatedSize).max())
        XCTAssertEqual(result.root.logicalSize, 32_768)
    }

    func testCancelledScanThrowsCancellationError() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<100 {
            let directory = root.appendingPathComponent("folder-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index % 255), count: 512)
                .write(to: directory.appendingPathComponent("file.bin"))
        }

        let task = Task {
            try await DiskScanner().scan(
                url: root,
                options: .default
            ) { _ in }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the scan to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
