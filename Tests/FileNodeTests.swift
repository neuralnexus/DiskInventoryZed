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
}
