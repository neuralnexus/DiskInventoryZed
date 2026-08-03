import Foundation
import XCTest
@testable import DiskInventoryZed

final class FileNodeTests: XCTestCase {
    func testPathLookupAndRemovalKeepSnapshotsImmutable() {
        let file = FileNode(
            url: URL(fileURLWithPath: "/tmp/root/folder/file.bin"),
            name: "file.bin",
            kind: .file,
            logicalSize: 10,
            allocatedSize: 16
        )
        let folder = FileNode(
            url: URL(fileURLWithPath: "/tmp/root/folder"),
            name: "folder",
            kind: .directory,
            logicalSize: 10,
            allocatedSize: 16,
            children: [file]
        )
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp/root"),
            name: "root",
            kind: .directory,
            logicalSize: 10,
            allocatedSize: 16,
            children: [folder]
        )

        XCTAssertEqual(root.path(to: file.id)?.map(\.displayName), ["root", "folder", "file.bin"])

        let updated = root.removingDescendant(withID: file.id)
        XCTAssertEqual(root.allocatedSize, 16)
        XCTAssertEqual(root.children.first?.children.count, 1)
        XCTAssertEqual(updated.allocatedSize, 0)
        XCTAssertEqual(updated.children.first?.children.count, 0)
    }

    func testDirectoryChildrenOnlyReturnsNavigableDirectories() {
        let file = FileNode(
            url: URL(fileURLWithPath: "/tmp/file"),
            name: "file",
            kind: .file,
            logicalSize: 1,
            allocatedSize: 1
        )
        let directory = FileNode(
            url: URL(fileURLWithPath: "/tmp/folder"),
            name: "folder",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 1,
            allocatedSize: 1,
            children: [file, directory]
        )

        XCTAssertEqual(root.directoryChildren?.map(\.id), [directory.id])
    }

    func testVeryDeepTreesCanBeSearchedAndUpdatedWithoutRecursion() {
        let depth = 5_000
        var node = FileNode(
            url: URL(fileURLWithPath: "/tmp/deep/leaf.bin"),
            name: "leaf.bin",
            kind: .file,
            logicalSize: 1,
            allocatedSize: 4_096
        )
        let leafID = node.id

        for index in (0..<depth).reversed() {
            node = FileNode(
                id: "/tmp/deep/\(index)",
                url: URL(fileURLWithPath: "/tmp/deep/\(index)"),
                name: String(index),
                kind: .directory,
                logicalSize: node.logicalSize,
                allocatedSize: node.allocatedSize,
                children: [node]
            )
        }

        XCTAssertEqual(node.path(to: leafID)?.count, depth + 1)
        XCTAssertNotNil(node.findChild(withID: leafID))

        let updated = node.removingDescendant(withID: leafID)
        XCTAssertNil(updated.findChild(withID: leafID))
        XCTAssertEqual(updated.allocatedSize, 0)
    }

    func testHiddenPackageCountsSurviveImmutableTreeUpdates() {
        let package = FileNode(
            url: URL(fileURLWithPath: "/tmp/App.app"),
            name: "App.app",
            kind: .package,
            isPackage: true,
            logicalSize: 1_000,
            allocatedSize: 2_000,
            totalFileCount: 12,
            totalDirectoryCount: 4
        )
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: package.logicalSize,
            allocatedSize: package.allocatedSize,
            children: [package]
        )

        XCTAssertEqual(root.descendantCounts().files, 12)
        XCTAssertEqual(root.descendantCounts().directories, 5)

        let updated = root.removingDescendant(withID: package.id)
        XCTAssertEqual(updated.descendantCounts().files, 0)
        XCTAssertEqual(updated.descendantCounts().directories, 1)
    }

    func testSizeAndCountReductionsSaturateOnOverflow() {
        let maximum = FileNode(
            url: URL(fileURLWithPath: "/tmp/overflow/maximum"),
            name: "maximum",
            kind: .file,
            logicalSize: .max,
            allocatedSize: .max,
            totalFileCount: .max,
            totalDirectoryCount: .max
        )
        let overflow = FileNode(
            url: URL(fileURLWithPath: "/tmp/overflow/overflow"),
            name: "overflow",
            kind: .file,
            logicalSize: 1,
            allocatedSize: 1,
            totalFileCount: 1,
            totalDirectoryCount: 1
        )
        let removable = FileNode(
            url: URL(fileURLWithPath: "/tmp/overflow/removable"),
            name: "removable",
            kind: .file,
            logicalSize: 1,
            allocatedSize: 1
        )
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp/overflow"),
            name: "overflow",
            kind: .directory,
            logicalSize: .max,
            allocatedSize: .max,
            children: [maximum, overflow, removable]
        )

        XCTAssertEqual(root.totalFileCount, .max)
        XCTAssertEqual(root.totalDirectoryCount, .max)

        let updated = root.removingDescendant(withID: removable.id)

        XCTAssertEqual(updated.logicalSize, .max)
        XCTAssertEqual(updated.allocatedSize, .max)
        XCTAssertEqual(updated.totalFileCount, .max)
        XCTAssertEqual(updated.totalDirectoryCount, .max)
    }
}
