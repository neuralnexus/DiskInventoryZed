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
        XCTAssertEqual(json?["schemaVersion"] as? Int, 2)

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertTrue(csv.contains("allocated_bytes"))
        XCTAssertTrue(csv.contains("\"a,\"\"quoted\"\".bin\""))
        XCTAssertTrue(csv.contains(",4096,1024,"))
    }
}
