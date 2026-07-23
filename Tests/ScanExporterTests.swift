import Foundation
import XCTest
@testable import DiskInventoryZed

final class ScanExporterTests: XCTestCase {
    func testJSONAndCSVExportsContainSizeAndReliabilityMetadata() throws {
        let file = FileNode(
            url: URL(fileURLWithPath: "/tmp/a,\"quoted\".bin"),
            name: "a,\"quoted\".bin",
            kind: .file,
            logicalSize: 1_024,
            allocatedSize: 4_096,
            isHardLinkDuplicate: true
        )
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 1_024,
            allocatedSize: 4_096,
            children: [file]
        )
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let jsonURL = outputDirectory.appendingPathComponent("scan.json")
        let csvURL = outputDirectory.appendingPathComponent("scan.csv")
        try ScanExporter.exportJSON(root: root, diagnostics: .empty, to: jsonURL)
        try ScanExporter.exportCSV(root: root, to: csvURL)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 3)
        XCTAssertEqual(json?["rootPath"] as? String, "/tmp")

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertTrue(csv.contains("allocated_bytes"))
        XCTAssertTrue(csv.contains("\"a,\"\"quoted\"\".bin\""))
        XCTAssertTrue(csv.contains(",4096,1024,"))

        let imported = try ScanExporter.importSnapshot(from: jsonURL)
        XCTAssertEqual(imported.schemaVersion, 3)
        XCTAssertEqual(imported.rootPath, "/tmp")
        XCTAssertEqual(imported.entries.count, 2)
        XCTAssertEqual(imported.entries.first(where: { $0.path == file.path })?.logicalSize, 1_024)
    }

    func testSnapshotComparisonReportsGrowthRemovalAndAddition() throws {
        let baselineEntries = [
            JSONExportEntry(
                path: "/tmp",
                parentPath: nil,
                name: "tmp",
                kind: .directory,
                isPackage: false,
                isSymbolicLink: false,
                allocatedSize: 300,
                logicalSize: 300,
                childCount: 2,
                creationDate: nil,
                modificationDate: nil,
                isHardLinkDuplicate: false,
                issue: nil
            ),
            JSONExportEntry(
                path: "/tmp/grows.bin",
                parentPath: "/tmp",
                name: "grows.bin",
                kind: .file,
                isPackage: false,
                isSymbolicLink: false,
                allocatedSize: 100,
                logicalSize: 100,
                childCount: 0,
                creationDate: nil,
                modificationDate: nil,
                isHardLinkDuplicate: false,
                issue: nil
            ),
            JSONExportEntry(
                path: "/tmp/removed.bin",
                parentPath: "/tmp",
                name: "removed.bin",
                kind: .file,
                isPackage: false,
                isSymbolicLink: false,
                allocatedSize: 200,
                logicalSize: 200,
                childCount: 0,
                creationDate: nil,
                modificationDate: nil,
                isHardLinkDuplicate: false,
                issue: nil
            )
        ]
        let baseline = ImportedScanSnapshot(
            schemaVersion: 3,
            exportedAt: Date(timeIntervalSince1970: 1_000),
            rootPath: "/tmp",
            entries: baselineEntries,
            diagnostics: .empty
        )
        let grown = FileNode(
            url: URL(fileURLWithPath: "/tmp/grows.bin"),
            name: "grows.bin",
            kind: .file,
            logicalSize: 250,
            allocatedSize: 250
        )
        let added = FileNode(
            url: URL(fileURLWithPath: "/tmp/added.bin"),
            name: "added.bin",
            kind: .file,
            logicalSize: 75,
            allocatedSize: 75
        )
        let current = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 325,
            allocatedSize: 325,
            children: [grown, added]
        )

        let comparison = try ScanSnapshotComparator.compare(current: current, with: baseline)
        XCTAssertEqual(comparison.totalDelta, 25)
        XCTAssertEqual(comparison.addedCount, 1)
        XCTAssertEqual(comparison.removedCount, 1)
        XCTAssertEqual(comparison.changedCount, 1)
        XCTAssertEqual(Set(comparison.largestGrowth.map(\.kind)), [.added, .grew])
        XCTAssertEqual(comparison.largestShrinkage.first?.kind, .removed)
    }
}
