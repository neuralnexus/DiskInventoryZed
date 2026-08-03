@preconcurrency import Foundation
#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#endif
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

#if os(Linux)
        for outputURL in [jsonURL, csvURL] {
            let permissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: outputURL.path)[.posixPermissions] as? NSNumber
            )
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }
#endif

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 4)
        XCTAssertEqual(json?["rootPath"] as? String, "/tmp")
        XCTAssertNotNil(json?["options"])

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertTrue(csv.contains("allocated_bytes"))
        XCTAssertTrue(csv.contains("\"a,\"\"quoted\"\".bin\""))
        XCTAssertTrue(csv.contains(",4096,1024,"))

        let imported = try ScanExporter.importSnapshot(from: jsonURL)
        XCTAssertEqual(imported.schemaVersion, 4)
        XCTAssertEqual(imported.rootPath, "/tmp")
        XCTAssertEqual(imported.options, .default)
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

        let comparison = try ScanSnapshotComparator.compare(
            current: current,
            options: .default,
            diagnostics: .empty,
            with: baseline
        )
        XCTAssertEqual(comparison.totalDelta, 25)
        XCTAssertEqual(comparison.addedCount, 1)
        XCTAssertEqual(comparison.removedCount, 1)
        XCTAssertEqual(comparison.changedCount, 1)
        XCTAssertEqual(Set(comparison.largestGrowth.map(\.kind)), [.added, .grew])
        XCTAssertEqual(comparison.largestShrinkage.first?.kind, .removed)
        XCTAssertNotNil(comparison.reliabilityWarning)
    }

    func testExistingDestinationPolicy() throws {
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedReplaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let jsonURL = outputDirectory.appendingPathComponent("scan.json")
        let csvURL = outputDirectory.appendingPathComponent("scan.csv")
        try Data("stale json".utf8).write(to: jsonURL)
        try Data("stale csv".utf8).write(to: csvURL)
#if os(Linux)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jsonURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: csvURL.path)
#endif

#if os(Linux)
        XCTAssertThrowsError(try ScanExporter.exportJSON(root: root, diagnostics: .empty, to: jsonURL))
        XCTAssertThrowsError(try ScanExporter.exportCSV(root: root, to: csvURL))
        XCTAssertEqual(try String(contentsOf: jsonURL, encoding: .utf8), "stale json")
        XCTAssertEqual(try String(contentsOf: csvURL, encoding: .utf8), "stale csv")
        let jsonPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: jsonURL.path)[.posixPermissions] as? NSNumber
        )
        let csvPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: csvURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(jsonPermissions.intValue & 0o777, 0o600)
        XCTAssertEqual(csvPermissions.intValue & 0o777, 0o600)
#else
        try ScanExporter.exportJSON(root: root, diagnostics: .empty, to: jsonURL)
        try ScanExporter.exportCSV(root: root, to: csvURL)
        XCTAssertNoThrow(try ScanExporter.importSnapshot(from: jsonURL))
        XCTAssertTrue(try String(contentsOf: csvURL, encoding: .utf8).hasPrefix("path,parent_path"))
#endif
    }

    func testSnapshotImportRejectsNegativeSizesBeforeComparison() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedInvalidSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let snapshotURL = outputDirectory.appendingPathComponent("invalid.json")
        let snapshot = """
        {"schemaVersion":3,"exportedAt":"1970-01-01T00:00:00Z","rootPath":"/tmp","diagnostics":{"unreadableItems":0,"skippedDirectories":0,"symbolicLinks":0,"packages":0,"duplicateHardLinks":0,"revisitedDirectories":0,"firstUnreadablePaths":[]},"entries":[{"path":"/tmp","name":"tmp","kind":"directory","isPackage":false,"isSymbolicLink":false,"allocatedSize":-9223372036854775808,"logicalSize":0,"childCount":0,"isHardLinkDuplicate":false}]}
        """
        try Data(snapshot.utf8).write(to: snapshotURL)

        XCTAssertThrowsError(try ScanExporter.importSnapshot(from: snapshotURL))
    }

    func testSnapshotComparisonRejectsMalformedDirectInput() throws {
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let invalidRoot = JSONExportEntry(
            path: "/tmp",
            parentPath: nil,
            name: "tmp",
            kind: .directory,
            isPackage: false,
            isSymbolicLink: false,
            allocatedSize: Int64.min,
            logicalSize: 0,
            childCount: 0,
            creationDate: nil,
            modificationDate: nil,
            isHardLinkDuplicate: false,
            issue: nil
        )
        let baseline = ImportedScanSnapshot(
            schemaVersion: 3,
            exportedAt: Date(),
            rootPath: "/tmp",
            entries: [invalidRoot],
            diagnostics: .empty
        )

        XCTAssertThrowsError(try ScanSnapshotComparator.compare(
            current: root,
            options: .default,
            diagnostics: .empty,
            with: baseline
        ))
    }

    func testSnapshotComparisonRejectsInconsistentDirectorySize() throws {
        let currentFile = FileNode(
            url: URL(fileURLWithPath: "/tmp/file.bin"),
            name: "file.bin",
            kind: .file,
            logicalSize: 1,
            allocatedSize: 1
        )
        let current = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 1,
            allocatedSize: 1,
            children: [currentFile]
        )
        let invalidRoot = JSONExportEntry(
            path: "/tmp",
            parentPath: nil,
            name: "tmp",
            kind: .directory,
            isPackage: false,
            isSymbolicLink: false,
            allocatedSize: 999,
            logicalSize: 999,
            childCount: 1,
            creationDate: nil,
            modificationDate: nil,
            isHardLinkDuplicate: false,
            issue: nil
        )
        let baseline = ImportedScanSnapshot(
            schemaVersion: 3,
            exportedAt: Date(),
            rootPath: "/tmp",
            entries: [invalidRoot, JSONExportEntry(node: currentFile, parentPath: "/tmp")],
            diagnostics: .empty
        )

        XCTAssertThrowsError(try ScanSnapshotComparator.compare(
            current: current,
            options: .default,
            diagnostics: .empty,
            with: baseline
        ))
    }

    func testSnapshotComparisonRejectsUnsupportedDirectSchema() throws {
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let baseline = ImportedScanSnapshot(
            schemaVersion: 5,
            exportedAt: Date(),
            rootPath: "/tmp",
            entries: [JSONExportEntry(node: root, parentPath: nil)],
            diagnostics: .empty
        )

        XCTAssertThrowsError(try ScanSnapshotComparator.compare(
            current: root,
            options: .default,
            diagnostics: .empty,
            with: baseline
        ))
    }

    func testSnapshotComparisonRejectsNonCanonicalPaths() throws {
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let rootEntry = JSONExportEntry(
            path: "/tmp",
            parentPath: nil,
            name: "tmp",
            kind: .directory,
            isPackage: false,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            childCount: 1,
            creationDate: nil,
            modificationDate: nil,
            isHardLinkDuplicate: false,
            issue: nil
        )
        let invalidChild = JSONExportEntry(
            path: "/tmp/..",
            parentPath: "/tmp",
            name: "..",
            kind: .file,
            isPackage: false,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            childCount: 0,
            creationDate: nil,
            modificationDate: nil,
            isHardLinkDuplicate: false,
            issue: nil
        )
        let baseline = ImportedScanSnapshot(
            schemaVersion: 3,
            exportedAt: Date(),
            rootPath: "/tmp",
            entries: [rootEntry, invalidChild],
            diagnostics: .empty
        )

        XCTAssertThrowsError(try ScanSnapshotComparator.compare(
            current: root,
            options: .default,
            diagnostics: .empty,
            with: baseline
        ))
    }

    func testSnapshotComparisonRejectsMismatchedSchemaFourOptions() throws {
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let baseline = ImportedScanSnapshot(
            schemaVersion: 4,
            exportedAt: Date(),
            rootPath: "/tmp",
            entries: [JSONExportEntry(node: root, parentPath: nil)],
            diagnostics: .empty,
            options: ScanOptions(
                skipDeveloperFolders: true,
                showHiddenFiles: false,
                showPackageContents: true,
                followSymlinks: false
            )
        )

        XCTAssertThrowsError(try ScanSnapshotComparator.compare(
            current: root,
            options: .default,
            diagnostics: .empty,
            with: baseline
        ))
    }

    func testSnapshotImportRejectsSchemaFourWithoutOptions() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedMissingOptionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let snapshotURL = outputDirectory.appendingPathComponent("snapshot.json")
        let snapshot = """
        {"schemaVersion":4,"exportedAt":"1970-01-01T00:00:00Z","rootPath":"/tmp","diagnostics":{"unreadableItems":0,"skippedDirectories":0,"symbolicLinks":0,"packages":0,"duplicateHardLinks":0,"revisitedDirectories":0,"firstUnreadablePaths":[]},"entries":[{"path":"/tmp","name":"tmp","kind":"directory","isPackage":false,"isSymbolicLink":false,"allocatedSize":0,"logicalSize":0,"childCount":0,"isHardLinkDuplicate":false}]}
        """
        try Data(snapshot.utf8).write(to: snapshotURL)

        XCTAssertThrowsError(try ScanExporter.importSnapshot(from: snapshotURL))
    }

    func testLegacySchemaTwoAndThreeSnapshotsImportWithReliabilityWarning() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedLegacySnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let current = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )

        for schemaVersion in 2...3 {
            let snapshotURL = outputDirectory.appendingPathComponent("schema-\(schemaVersion).json")
            let snapshot = """
            {"schemaVersion":\(schemaVersion),"exportedAt":"1970-01-01T00:00:00Z","rootPath":"/tmp","diagnostics":{},"entries":[{"path":"/tmp","name":"tmp","kind":"directory","isPackage":false,"isSymbolicLink":false,"allocatedSize":0,"logicalSize":0,"childCount":0,"isHardLinkDuplicate":false}]}
            """
            try Data(snapshot.utf8).write(to: snapshotURL)

            let imported = try ScanExporter.importSnapshot(from: snapshotURL)
            let comparison = try ScanSnapshotComparator.compare(
                current: current,
                options: .default,
                diagnostics: .empty,
                with: imported
            )

            XCTAssertEqual(imported.schemaVersion, schemaVersion)
            XCTAssertNil(imported.options)
            XCTAssertNotNil(comparison.reliabilityWarning)
        }
    }

    func testSchemaFourComparisonWarningsReflectCoverage() throws {
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let entry = JSONExportEntry(node: root, parentPath: nil)
        let complete = ImportedScanSnapshot(
            schemaVersion: 4,
            exportedAt: Date(),
            rootPath: "/tmp",
            entries: [entry],
            diagnostics: .empty,
            options: .default
        )
        let incomplete = ImportedScanSnapshot(
            schemaVersion: 4,
            exportedAt: Date(),
            rootPath: "/tmp",
            entries: [entry],
            diagnostics: ScanDiagnostics(skippedDirectories: 1),
            options: .default
        )

        let completeComparison = try ScanSnapshotComparator.compare(
            current: root,
            options: .default,
            diagnostics: .empty,
            with: complete
        )
        let baselineIncomplete = try ScanSnapshotComparator.compare(
            current: root,
            options: .default,
            diagnostics: .empty,
            with: incomplete
        )
        let currentIncomplete = try ScanSnapshotComparator.compare(
            current: root,
            options: .default,
            diagnostics: ScanDiagnostics(unreadableItems: 1),
            with: complete
        )

        XCTAssertNil(completeComparison.reliabilityWarning)
        XCTAssertNotNil(baselineIncomplete.reliabilityWarning)
        XCTAssertNotNil(currentIncomplete.reliabilityWarning)
    }

    func testSnapshotImportRejectsOversizedSparseFile() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedOversizedSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let snapshotURL = outputDirectory.appendingPathComponent("snapshot.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: snapshotURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: snapshotURL)
        try handle.truncate(atOffset: UInt64(ScanExporter.maximumSnapshotBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try ScanExporter.importSnapshot(from: snapshotURL))
    }

    func testSnapshotImportRejectsExcessDiagnosticPathsDuringDecode() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedDiagnosticLimitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let snapshotURL = outputDirectory.appendingPathComponent("snapshot.json")
        let paths = (0..<21).map { "\"/tmp/unreadable-\($0)\"" }.joined(separator: ",")
        let snapshot = """
        {"schemaVersion":3,"exportedAt":"1970-01-01T00:00:00Z","rootPath":"/tmp","diagnostics":{"unreadableItems":21,"firstUnreadablePaths":[\(paths)]},"entries":[{"path":"/tmp","name":"tmp","kind":"directory","isPackage":false,"isSymbolicLink":false,"allocatedSize":0,"logicalSize":0,"childCount":0,"isHardLinkDuplicate":false}]}
        """
        try Data(snapshot.utf8).write(to: snapshotURL)

        XCTAssertThrowsError(try ScanExporter.importSnapshot(from: snapshotURL))
    }

    func testSnapshotValidatorRejectsOversizedPath() throws {
        let path = "/" + String(repeating: "a", count: ScanExporter.maximumSnapshotPathBytes)
        let root = JSONExportEntry(
            path: path,
            parentPath: nil,
            name: "root",
            kind: .directory,
            isPackage: false,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            childCount: 0,
            creationDate: nil,
            modificationDate: nil,
            isHardLinkDuplicate: false,
            issue: nil
        )

        XCTAssertThrowsError(try ScanSnapshotValidator.validate(
            entries: [root],
            declaredRootPath: path,
            diagnostics: .empty
        ))
    }

    func testComparisonRetainsOnlyLargestHundredChanges() throws {
        let currentFiles = (0..<600).map { index in
            FileNode(
                url: URL(fileURLWithPath: "/tmp/file-\(index)"),
                name: "file-\(index)",
                kind: .file,
                logicalSize: Int64(index),
                allocatedSize: Int64(index)
            )
        }
        let current = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0,
            children: currentFiles
        )
        let baselineRoot = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let baseline = ImportedScanSnapshot(
            schemaVersion: 3,
            exportedAt: Date(),
            rootPath: "/tmp",
            entries: [JSONExportEntry(node: baselineRoot, parentPath: nil)],
            diagnostics: .empty
        )

        let comparison = try ScanSnapshotComparator.compare(
            current: current,
            options: .default,
            diagnostics: .empty,
            with: baseline
        )

        XCTAssertEqual(comparison.addedCount, 600)
        XCTAssertEqual(comparison.largestGrowth.count, 100)
        XCTAssertEqual(comparison.largestGrowth.first?.currentSize, 599)
        XCTAssertEqual(comparison.largestGrowth.last?.currentSize, 500)
    }

    func testCSVProtectsSpreadsheetFormulaFields() throws {
        let formulas = ["=2+2", " +1", "\t-1", "@cmd", "＝1", "−1"]
        let files = formulas.enumerated().map { index, formula in
            FileNode(
                url: URL(fileURLWithPath: "/tmp/formula-\(index)"),
                name: formula,
                kind: .file,
                logicalSize: 1,
                allocatedSize: 1
            )
        }
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: Int64(files.count),
            allocatedSize: Int64(files.count),
            children: files
        )
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedCSVFormulaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let output = outputDirectory.appendingPathComponent("scan.csv")

        try ScanExporter.exportCSV(root: root, to: output)

        let csv = try String(contentsOf: output, encoding: .utf8)
        for formula in formulas {
            XCTAssertTrue(csv.contains("\"'\(formula)\""))
        }
    }

#if os(Linux)
    func testLinuxDottedScanPathExportsImportableSnapshot() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedDottedPathTests-\(UUID().uuidString)", isDirectory: true)
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let dottedSource = URL(fileURLWithPath: source.path + "/.", isDirectory: true)
        let result = try await DiskScanner().scan(url: dottedSource, options: .default) { _ in }
        let output = workspace.appendingPathComponent("scan.json")

        try ScanExporter.exportJSON(root: result.root, diagnostics: result.diagnostics, to: output)
        let imported = try ScanExporter.importSnapshot(from: output)

        XCTAssertEqual(result.root.path, source.path)
        XCTAssertEqual(imported.rootPath, source.path)
    }

    func testLinuxConcurrentWritersPublishExactlyOneCompleteExport() async throws {
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedConcurrentExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let output = outputDirectory.appendingPathComponent("scan.json")

        let writers = (0..<2).map { _ in
            Task {
                do {
                    try ScanExporter.exportJSON(root: root, diagnostics: .empty, to: output)
                    return true
                } catch {
                    return false
                }
            }
        }
        var outcomes: [Bool] = []
        for writer in writers {
            outcomes.append(await writer.value)
        }

        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertNoThrow(try ScanExporter.importSnapshot(from: output))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path),
            ["scan.json"]
        )
    }

    func testLinuxCancelledExportLeavesNoOutputOrStagingDirectory() async throws {
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedCancelledExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let output = outputDirectory.appendingPathComponent("scan.json")
        let exportTask = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            try ScanExporter.exportJSON(root: root, diagnostics: .empty, to: output)
        }

        do {
            try await exportTask.value
            XCTFail("Expected export cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).isEmpty)
    }

    func testLinuxPreparedDestinationPinsValidatedParent() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedPinnedExportTests-\(UUID().uuidString)", isDirectory: true)
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        let outside = workspace.appendingPathComponent("outside", isDirectory: true)
        let alias = workspace.appendingPathComponent("output-parent")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let result = try await DiskScanner().scan(url: source, options: .default) { _ in }
        let aliasedOutput = alias.appendingPathComponent("scan.json")
        let destination = try ScanExporter.prepareLinuxDestination(
            for: aliasedOutput,
            excludingDirectoryIdentities: result.scannedDirectoryIdentities
        )

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        try ScanExporter.exportJSON(
            root: result.root,
            diagnostics: result.diagnostics,
            to: destination
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("scan.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("scan.json").path
        ))
    }

    func testLinuxPreparedDestinationRejectsParentMovedIntoScan() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedMovedExportTests-\(UUID().uuidString)", isDirectory: true)
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        let outside = workspace.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let result = try await DiskScanner().scan(url: source, options: .default) { _ in }
        let destination = try ScanExporter.prepareLinuxDestination(
            for: outside.appendingPathComponent("scan.json"),
            excludingDirectoryIdentities: result.scannedDirectoryIdentities
        )
        let movedParent = source.appendingPathComponent("moved-output", isDirectory: true)
        try FileManager.default.moveItem(at: outside, to: movedParent)

        XCTAssertThrowsError(try ScanExporter.exportJSON(
            root: result.root,
            diagnostics: result.diagnostics,
            to: destination
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: movedParent.appendingPathComponent("scan.json").path
        ))
    }

    func testLinuxPostScanRestrictionRejectsParentMovedIntoScan() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedRestrictedExportTests-\(UUID().uuidString)", isDirectory: true)
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        let outside = workspace.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let destination = try ScanExporter.prepareLinuxDestination(
            for: outside.appendingPathComponent("scan.json"),
            excludingDirectoryIdentities: []
        )
        let result = try await DiskScanner().scan(url: source, options: .default) { _ in }
        let movedParent = source.appendingPathComponent("moved-output", isDirectory: true)
        try FileManager.default.moveItem(at: outside, to: movedParent)

        XCTAssertThrowsError(try ScanExporter.restrictLinuxDestination(
            destination,
            excludingDirectoryIdentities: result.scannedDirectoryIdentities
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: movedParent.appendingPathComponent("scan.json").path
        ))
    }

    func testLinuxPreparedDestinationRejectsSkippedDirectoryAlias() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedAliasedExportTests-\(UUID().uuidString)", isDirectory: true)
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        let hidden = source.appendingPathComponent(".hidden", isDirectory: true)
        let alias = workspace.appendingPathComponent("output-parent")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: hidden)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let result = try await DiskScanner().scan(url: source, options: .default) { _ in }

        XCTAssertThrowsError(try ScanExporter.prepareLinuxDestination(
            for: alias.appendingPathComponent("scan.json"),
            excludingDirectoryIdentities: result.scannedDirectoryIdentities
        ))
    }

    func testLinuxSnapshotRoundTripPreservesCanonicallyEquivalentPaths() throws {
        let composedName = "\u{00E9}.bin"
        let decomposedName = "e\u{0301}.bin"
        let composed = FileNode(
            url: URL(fileURLWithPath: "/tmp/\(composedName)"),
            name: composedName,
            kind: .file,
            logicalSize: 1,
            allocatedSize: 1
        )
        let decomposed = FileNode(
            url: URL(fileURLWithPath: "/tmp/\(decomposedName)"),
            name: decomposedName,
            kind: .file,
            logicalSize: 2,
            allocatedSize: 2
        )
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 3,
            allocatedSize: 3,
            children: [composed, decomposed]
        )
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedUnicodeSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let snapshotURL = outputDirectory.appendingPathComponent("scan.json")

        try ScanExporter.exportJSON(root: root, diagnostics: .empty, to: snapshotURL)
        let imported = try ScanExporter.importSnapshot(from: snapshotURL)

        XCTAssertEqual(imported.entries.count, 3)
        XCTAssertEqual(Set(imported.entries.map { Data($0.path.utf8) }).count, 3)
    }

    func testSnapshotComparisonRejectsDisconnectedCycle() throws {
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let rootEntry = JSONExportEntry(node: root, parentPath: nil)
        let first = JSONExportEntry(
            path: "/tmp/a",
            parentPath: "/tmp/b",
            name: "a",
            kind: .directory,
            isPackage: false,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            childCount: 1,
            creationDate: nil,
            modificationDate: nil,
            isHardLinkDuplicate: false,
            issue: nil
        )
        let second = JSONExportEntry(
            path: "/tmp/b",
            parentPath: "/tmp/a",
            name: "b",
            kind: .directory,
            isPackage: false,
            isSymbolicLink: false,
            allocatedSize: 0,
            logicalSize: 0,
            childCount: 1,
            creationDate: nil,
            modificationDate: nil,
            isHardLinkDuplicate: false,
            issue: nil
        )
        let baseline = ImportedScanSnapshot(
            schemaVersion: 3,
            exportedAt: Date(),
            rootPath: "/tmp",
            entries: [rootEntry, first, second],
            diagnostics: .empty
        )

        XCTAssertThrowsError(try ScanSnapshotComparator.compare(
            current: root,
            options: .default,
            diagnostics: .empty,
            with: baseline
        ))
    }

    func testLinuxExportRefusesSymbolicLinkDestination() throws {
        let root = FileNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0
        )
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedSymlinkExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let target = outputDirectory.appendingPathComponent("target.json")
        let link = outputDirectory.appendingPathComponent("scan.json")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try ScanExporter.exportJSON(
            root: root,
            diagnostics: .empty,
            to: link
        ))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testLinuxExportRejectsNonStickyWorldWritableParent() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedUntrustedExportTests-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = workspace.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        XCTAssertEqual(outputDirectory.path.withCString {
            chmod($0, mode_t(0o777))
        }, 0)

        XCTAssertThrowsError(try ScanExporter.prepareLinuxDestination(
            for: outputDirectory.appendingPathComponent("scan.json"),
            excludingDirectoryIdentities: []
        ))
    }
#endif
}
