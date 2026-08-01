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

#if os(Linux)
    func testSparseFileUsesLinuxAllocatedBlockCount() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sparseFile = root.appendingPathComponent("sparse.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparseFile.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparseFile)
        try handle.truncate(atOffset: 64 * 1_024 * 1_024)
        try handle.close()

        let result = try await DiskScanner().scan(url: root, options: .default) { _ in }
        let node = try XCTUnwrap(result.root.findChild(at: sparseFile))

        XCTAssertEqual(node.logicalSize, 64 * 1_024 * 1_024)
        XCTAssertLessThan(node.allocatedSize, node.logicalSize)
    }

    func testLinuxHardLinkOwnerIsDeterministicAcrossDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstDirectory = root.appendingPathComponent("z-directory", isDirectory: true)
        let ownerDirectory = root.appendingPathComponent("a-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)

        let original = firstDirectory.appendingPathComponent("original.bin")
        let expectedOwner = ownerDirectory.appendingPathComponent("linked.bin")
        try Data(repeating: 0xA5, count: 16_384).write(to: original)
        try FileManager.default.linkItem(at: original, to: expectedOwner)

        for _ in 0..<10 {
            let result = try await DiskScanner().scan(url: root, options: .default) { _ in }
            let ownerNode = try XCTUnwrap(result.root.findChild(at: expectedOwner))
            let duplicateNode = try XCTUnwrap(result.root.findChild(at: original))

            XCTAssertFalse(ownerNode.isHardLinkDuplicate)
            XCTAssertGreaterThan(ownerNode.allocatedSize, 0)
            XCTAssertTrue(duplicateNode.isHardLinkDuplicate)
            XCTAssertEqual(duplicateNode.allocatedSize, 0)
        }
    }

    func testLinuxCanonicallyEquivalentNamesRemainDistinct() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let composedName = "\u{00E9}.bin"
        let decomposedName = "e\u{0301}.bin"
        XCTAssertNotEqual(Data(composedName.utf8), Data(decomposedName.utf8))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.path + "/" + composedName,
            contents: Data(repeating: 0x11, count: 4_096)
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.path + "/" + decomposedName,
            contents: Data(repeating: 0x22, count: 8_192)
        ))

        let result = try await DiskScanner().scan(url: root, options: .default) { _ in }
        let filesByName = Dictionary(uniqueKeysWithValues: result.root.children.map {
            (Data($0.displayName.utf8), $0)
        })

        XCTAssertEqual(result.totalFiles, 2)
        XCTAssertEqual(result.root.children.count, 2)
        XCTAssertEqual(filesByName[Data(composedName.utf8)]?.logicalSize, 4_096)
        XCTAssertEqual(filesByName[Data(decomposedName.utf8)]?.logicalSize, 8_192)
        XCTAssertEqual(Set(result.root.children.map(\.id)).count, 2)
    }

    func testLinuxDottedDirectoryIsNotTreatedAsPackage() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dottedDirectory = root.appendingPathComponent("project.d", isDirectory: true)
        try FileManager.default.createDirectory(at: dottedDirectory, withIntermediateDirectories: true)
        let file = dottedDirectory.appendingPathComponent("config")
        try Data("value".utf8).write(to: file)

        let result = try await DiskScanner().scan(url: root, options: .default) { _ in }
        let node = try XCTUnwrap(result.root.findChild(at: dottedDirectory))

        XCTAssertTrue(node.isDirectory)
        XCTAssertFalse(node.isPackage)
        XCTAssertNotNil(result.root.findChild(at: file))
        XCTAssertEqual(result.diagnostics.packages, 0)
    }

    func testLinuxDirectorySymlinkIsFollowedOnlyWhenRequested() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let root = workspace.appendingPathComponent("scan", isDirectory: true)
        let target = workspace.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("linked".utf8).write(to: target.appendingPathComponent("file.txt"))

        let link = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let noFollow = try await DiskScanner().scan(
            url: root,
            options: ScanOptions(
                skipDeveloperFolders: false,
                showHiddenFiles: true,
                showPackageContents: true,
                followSymlinks: false
            )
        ) { _ in }
        let unvisitedLink = try XCTUnwrap(noFollow.root.findChild(at: link))
        XCTAssertEqual(unvisitedLink.kind, .symbolicLink)
        XCTAssertTrue(unvisitedLink.children.isEmpty)

        let follow = try await DiskScanner().scan(
            url: root,
            options: ScanOptions(
                skipDeveloperFolders: false,
                showHiddenFiles: true,
                showPackageContents: true,
                followSymlinks: true
            )
        ) { _ in }
        let visitedLink = try XCTUnwrap(follow.root.findChild(at: link))
        XCTAssertTrue(visitedLink.isDirectory)
        XCTAssertTrue(visitedLink.isSymbolicLink)
        XCTAssertEqual(visitedLink.children.map(\.displayName), ["file.txt"])
    }

    func testLinuxBrokenSymlinkRetainsLinkMetadataWhenFollowing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let link = root.appendingPathComponent("broken-link")
        let missingTarget = root.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missingTarget)

        let result = try await DiskScanner().scan(
            url: root,
            options: ScanOptions(
                skipDeveloperFolders: false,
                showHiddenFiles: true,
                showPackageContents: true,
                followSymlinks: true
            )
        ) { _ in }
        let node = try XCTUnwrap(result.root.findChild(at: link))

        XCTAssertEqual(node.kind, .symbolicLink)
        XCTAssertTrue(node.isSymbolicLink)
        XCTAssertNotNil(node.errorDescription)
        XCTAssertEqual(result.diagnostics.symbolicLinks, 1)
        XCTAssertEqual(result.diagnostics.unreadableItems, 1)
    }

    func testLinuxFollowedDirectoryAliasOwnerIsDeterministic() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let root = workspace.appendingPathComponent("scan", isDirectory: true)
        let target = workspace.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("target".utf8).write(to: target.appendingPathComponent("file.txt"))

        let laterAlias = root.appendingPathComponent("z-link")
        let expectedOwner = root.appendingPathComponent("a-link")
        try FileManager.default.createSymbolicLink(at: laterAlias, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: expectedOwner, withDestinationURL: target)

        for _ in 0..<10 {
            let result = try await DiskScanner().scan(
                url: root,
                options: ScanOptions(
                    skipDeveloperFolders: false,
                    showHiddenFiles: true,
                    showPackageContents: true,
                    followSymlinks: true
                )
            ) { _ in }
            let owner = try XCTUnwrap(result.root.findChild(at: expectedOwner))
            let revisited = try XCTUnwrap(result.root.findChild(at: laterAlias))

            XCTAssertEqual(owner.children.map(\.displayName), ["file.txt"])
            XCTAssertTrue(revisited.children.isEmpty)
            XCTAssertNotNil(revisited.errorDescription)
            XCTAssertEqual(result.diagnostics.revisitedDirectories, 1)
        }
    }
#endif

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
