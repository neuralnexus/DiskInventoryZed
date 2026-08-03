@preconcurrency import Foundation
#if os(Linux)
import Glibc
#endif
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
        XCTAssertFalse(result.scannedDirectoryIdentities.isEmpty)
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

    func testLinuxHardLinkedSymbolicLinksAreDeduplicated() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("original-link")
        let linked = root.appendingPathComponent("linked-link")
        try FileManager.default.createSymbolicLink(
            at: original,
            withDestinationURL: root.appendingPathComponent("missing-target")
        )
        let linkResult = original.path.withCString { originalPath in
            linked.path.withCString { linkedPath in
                Glibc.link(originalPath, linkedPath)
            }
        }
        XCTAssertEqual(linkResult, 0)

        var linkStatus = stat()
        XCTAssertEqual(original.path.withCString { Glibc.lstat($0, &linkStatus) }, 0)
        XCTAssertEqual(linkStatus.st_nlink, 2)

        let result = try await DiskScanner().scan(url: root, options: .default) { _ in }
        let links = result.root.children.filter(\.isSymbolicLink)

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.filter(\.isHardLinkDuplicate).count, 1)
        XCTAssertEqual(result.diagnostics.symbolicLinks, 2)
        XCTAssertEqual(result.diagnostics.duplicateHardLinks, 1)
        XCTAssertEqual(result.totalFiles, 2)
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

    func testLinuxDirectorySymlinkIsNeverFollowed() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let root = workspace.appendingPathComponent("scan", isDirectory: true)
        let target = workspace.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("linked".utf8).write(to: target.appendingPathComponent("file.txt"))

        let link = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = try await DiskScanner().scan(
            url: root,
            options: ScanOptions(
                skipDeveloperFolders: false,
                showHiddenFiles: true,
                showPackageContents: true,
                followSymlinks: true
            )
        ) { _ in }
        let unvisitedLink = try XCTUnwrap(result.root.findChild(at: link))
        XCTAssertEqual(unvisitedLink.kind, .symbolicLink)
        XCTAssertTrue(unvisitedLink.children.isEmpty)
        XCTAssertEqual(result.diagnostics.symbolicLinks, 1)
        XCTAssertEqual(result.totalFiles, 1)
    }

    func testLinuxBrokenSymlinkIsReportedAsALinkRatherThanUnreadable() async throws {
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
        XCTAssertNil(node.errorDescription)
        XCTAssertEqual(result.diagnostics.symbolicLinks, 1)
        XCTAssertEqual(result.diagnostics.unreadableItems, 0)
    }

    func testLinuxRejectsSymbolicLinkScanRoot() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let rootLink = workspace.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: target)

        do {
            _ = try await DiskScanner().scan(url: rootLink, options: .default) { _ in }
            XCTFail("Expected a symbolic-link scan root to be rejected")
        } catch {
            // Expected.
        }
    }

    func testLinuxRejectsSymbolicLinkInScanRootAncestors() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let realRoot = workspace.appendingPathComponent("real", isDirectory: true)
        let nested = realRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let alias = workspace.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realRoot)
        let aliasedNested = alias.appendingPathComponent("nested", isDirectory: true)

        do {
            _ = try await DiskScanner().scan(url: aliasedNested, options: .default) { _ in }
            XCTFail("Expected a symlinked scan-root ancestor to be rejected")
        } catch {
            // Expected.
        }
    }

    func testLinuxRejectsParentComponentAfterSymbolicLinkBeforeNormalization() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let scanRoot = workspace.appendingPathComponent("scan", isDirectory: true)
        let linkTarget = workspace.appendingPathComponent("link-target", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkTarget, withIntermediateDirectories: true)
        let link = workspace.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linkTarget)
        let unnormalized = URL(
            fileURLWithPath: workspace.path + "/alias/../scan",
            isDirectory: true
        )

        do {
            _ = try await DiskScanner().scan(url: unnormalized, options: .default) { _ in }
            XCTFail("Expected a parent path component to be rejected")
        } catch DiskScanner.ScanError.invalidURL {
            // Expected.
        } catch {
            XCTFail("Expected invalidURL, received \(error)")
        }
    }

    func testLinuxRejectsParentComponentAfterNonexistentEntryBeforeNormalization() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let scanRoot = workspace.appendingPathComponent("scan", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        let unnormalized = URL(
            fileURLWithPath: workspace.path + "/missing/../scan",
            isDirectory: true
        )

        do {
            _ = try await DiskScanner().scan(url: unnormalized, options: .default) { _ in }
            XCTFail("Expected a parent path component to be rejected")
        } catch DiskScanner.ScanError.invalidURL {
            // Expected.
        } catch {
            XCTFail("Expected invalidURL, received \(error)")
        }
    }

    func testLinuxRemovesCurrentDirectoryComponentsFromScanRoot() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let scanRoot = workspace.appendingPathComponent("scan", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: scanRoot.appendingPathComponent("file.txt"))
        let unnormalized = URL(
            fileURLWithPath: workspace.path + "/./scan",
            isDirectory: true
        )

        let result = try await DiskScanner().scan(url: unnormalized, options: .default) { _ in }

        XCTAssertEqual(result.root.path, scanRoot.path)
        XCTAssertEqual(result.totalFiles, 1)
    }

    func testLinuxAllowsExecuteOnlyScanRootAncestor() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let ancestor = workspace.appendingPathComponent("searchable", isDirectory: true)
        let root = ancestor.appendingPathComponent("scan", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: root.appendingPathComponent("file.txt"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o111],
            ofItemAtPath: ancestor.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: ancestor.path
            )
        }

        let result = try await DiskScanner().scan(url: root, options: .default) { _ in }

        XCTAssertEqual(result.totalFiles, 1)
    }

    func testLinuxVisibleNonUTF8FilesAreOpaqueNodesWithAccurateTotals() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directoryDescriptor = root.path.withCString {
            Glibc.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        let invalidNameBytes: [[UInt8]] = [[0xFF], [0xFE]]
        let invalidNames = invalidNameBytes.map { bytes in
            bytes.map { CChar(bitPattern: $0) } + [CChar(0)]
        }
        defer {
            for invalidName in invalidNames {
                _ = invalidName.withUnsafeBufferPointer {
                    Glibc.unlinkat(directoryDescriptor, $0.baseAddress!, 0)
                }
            }
            Glibc.close(directoryDescriptor)
        }

        var expectedLogicalSize: Int64 = 0
        var expectedAllocatedSize: Int64 = 0
        for (index, invalidName) in invalidNames.enumerated() {
            let fileDescriptor = invalidName.withUnsafeBufferPointer {
                Glibc.openat(
                    directoryDescriptor,
                    $0.baseAddress!,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            XCTAssertGreaterThanOrEqual(fileDescriptor, 0)
            let contents = Data(repeating: UInt8(index + 1), count: 4_097 + index * 2_048)
            let written = contents.withUnsafeBytes { bytes in
                Glibc.write(fileDescriptor, bytes.baseAddress!, bytes.count)
            }
            XCTAssertEqual(Int(written), contents.count)
            var status = stat()
            XCTAssertEqual(Glibc.fstat(fileDescriptor, &status), 0)
            expectedLogicalSize += Int64(status.st_size)
            expectedAllocatedSize += Int64(status.st_blocks) * 512
            Glibc.close(fileDescriptor)
        }

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
        XCTAssertEqual(result.totalDirectories, 1)
        XCTAssertEqual(result.root.totalFileCount, 2)
        XCTAssertEqual(result.root.logicalSize, expectedLogicalSize)
        XCTAssertEqual(result.root.allocatedSize, expectedAllocatedSize)
        XCTAssertEqual(result.root.children.count, 2)
        XCTAssertTrue(result.root.children.allSatisfy(\.isUnreadable))
        XCTAssertTrue(result.root.children.allSatisfy { $0.displayName.contains("non-UTF-8") })
        let expectedIDs = Set(invalidNameBytes.map { nameBytes in
            Data(Array(root.path.utf8) + [UInt8(ascii: "/")] + nameBytes).base64EncodedString()
        })
        XCTAssertEqual(Set(result.root.children.map(\.id)), expectedIDs)
        XCTAssertEqual(result.diagnostics.unreadableItems, 2)
        XCTAssertEqual(result.diagnostics.firstUnreadablePaths.count, 2)
        XCTAssertTrue(result.diagnostics.firstUnreadablePaths.allSatisfy { $0.contains("non-UTF-8") })
    }

    func testLinuxVisibleNonUTF8DirectoryExcludesMetadataSizeAndCountsDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directoryDescriptor = root.path.withCString {
            Glibc.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        let invalidName = [CChar(bitPattern: 0xFF), CChar(bitPattern: 0x44), CChar(0)]
        XCTAssertEqual(invalidName.withUnsafeBufferPointer {
            Glibc.mkdirat(directoryDescriptor, $0.baseAddress!, mode_t(0o700))
        }, 0)
        defer {
            _ = invalidName.withUnsafeBufferPointer {
                Glibc.unlinkat(directoryDescriptor, $0.baseAddress!, AT_REMOVEDIR)
            }
            Glibc.close(directoryDescriptor)
        }
        var status = stat()
        XCTAssertEqual(invalidName.withUnsafeBufferPointer {
            Glibc.fstatat(directoryDescriptor, $0.baseAddress!, &status, AT_SYMLINK_NOFOLLOW)
        }, 0)

        let result = try await DiskScanner().scan(
            url: root,
            options: ScanOptions(
                skipDeveloperFolders: false,
                showHiddenFiles: true,
                showPackageContents: true,
                followSymlinks: false
            )
        ) { _ in }
        let node = try XCTUnwrap(result.root.children.first)

        XCTAssertEqual(result.totalFiles, 0)
        XCTAssertEqual(result.totalDirectories, 2)
        XCTAssertEqual(result.root.totalDirectoryCount, 2)
        XCTAssertEqual(node.kind, .directory)
        XCTAssertEqual(node.logicalSize, 0)
        XCTAssertEqual(node.allocatedSize, 0)
        XCTAssertTrue(node.isUnreadable)
        XCTAssertEqual(result.diagnostics.unreadableItems, 1)
    }

    func testLinuxOpaqueNameDoesNotAliasRealPlaceholderName() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let placeholder = root.appendingPathComponent("<non-UTF-8:_w>")
        try Data("valid".utf8).write(to: placeholder)

        let directoryDescriptor = root.path.withCString {
            Glibc.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        let invalidName = [CChar(bitPattern: 0xFF), CChar(0)]
        let invalidDescriptor = invalidName.withUnsafeBufferPointer {
            Glibc.openat(
                directoryDescriptor,
                $0.baseAddress!,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        XCTAssertGreaterThanOrEqual(invalidDescriptor, 0)
        Glibc.close(invalidDescriptor)
        defer {
            _ = invalidName.withUnsafeBufferPointer {
                Glibc.unlinkat(directoryDescriptor, $0.baseAddress!, 0)
            }
            Glibc.close(directoryDescriptor)
        }

        let result = try await DiskScanner().scan(
            url: root,
            options: ScanOptions(
                skipDeveloperFolders: false,
                showHiddenFiles: true,
                showPackageContents: true,
                followSymlinks: false
            )
        ) { _ in }
        let opaqueNode = try XCTUnwrap(result.root.children.first(where: \.isUnreadable))

        XCTAssertEqual(result.root.children.count, 2)
        XCTAssertEqual(Set(result.root.children.map(\.path)).count, 2)
        XCTAssertNotEqual(opaqueNode.path, placeholder.path)
        XCTAssertNotEqual(opaqueNode.displayName, placeholder.lastPathComponent)
    }

    func testLinuxWideTreeCompletesAfterQueueCompaction() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<2_100 {
            let directory = root.appendingPathComponent("directory-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data([UInt8(index % 255)]).write(
                to: directory.appendingPathComponent("marker")
            )
        }

        let result = try await DiskScanner().scan(url: root, options: .default) { _ in }

        XCTAssertEqual(result.totalFiles, 2_100)
        XCTAssertEqual(result.totalDirectories, 2_101)
        XCTAssertEqual(result.root.children.count, 2_100)
        XCTAssertNotNil(result.root.findChild(
            at: root.appendingPathComponent("directory-2099/marker")
        ))
    }

    func testLinuxHiddenNonUTF8DirectoryDoesNotRetainObservedIdentity() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directoryDescriptor = root.path.withCString {
            Glibc.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        let invalidName = [
            CChar(bitPattern: UInt8(ascii: ".")),
            CChar(bitPattern: 0xFF),
            CChar(0)
        ]
        XCTAssertEqual(invalidName.withUnsafeBufferPointer {
            Glibc.mkdirat(directoryDescriptor, $0.baseAddress!, mode_t(0o700))
        }, 0)
        defer {
            _ = invalidName.withUnsafeBufferPointer {
                Glibc.unlinkat(directoryDescriptor, $0.baseAddress!, AT_REMOVEDIR)
            }
            Glibc.close(directoryDescriptor)
        }
        var status = stat()
        XCTAssertEqual(invalidName.withUnsafeBufferPointer {
            Glibc.fstatat(directoryDescriptor, $0.baseAddress!, &status, AT_SYMLINK_NOFOLLOW)
        }, 0)
        let hiddenIdentity = "\(status.st_dev)|\(status.st_ino)"

        let result = try await DiskScanner().scan(url: root, options: .default) { _ in }

        XCTAssertTrue(result.root.children.isEmpty)
        XCTAssertEqual(result.totalDirectories, 1)
        XCTAssertEqual(result.diagnostics.unreadableItems, 0)
        XCTAssertFalse(result.scannedDirectoryIdentities.contains(hiddenIdentity))
    }
#endif

#if os(macOS)
    func testMacPackageContentsContributeTotalsWhileChildrenStayHidden() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Example.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let payload = contents.appendingPathComponent("payload.bin")
        try Data(repeating: 0xA5, count: 8_192).write(to: payload)

        let result = try await DiskScanner().scan(
            url: root,
            options: ScanOptions(
                skipDeveloperFolders: false,
                showHiddenFiles: true,
                showPackageContents: false,
                followSymlinks: false
            )
        ) { _ in }
        let packageNode = try XCTUnwrap(result.root.children.first)

        XCTAssertTrue(packageNode.isPackage)
        XCTAssertTrue(packageNode.children.isEmpty)
        XCTAssertEqual(packageNode.totalFileCount, 1)
        XCTAssertGreaterThanOrEqual(packageNode.logicalSize, 8_192)
        XCTAssertGreaterThan(packageNode.allocatedSize, 0)
    }
#endif

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
