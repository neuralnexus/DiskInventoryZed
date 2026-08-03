#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import XCTest
@testable import DiskInventoryZed

final class LinuxCLITests: XCTestCase {
    func testParserBuildsSafeScanConfiguration() throws {
        let result = try LinuxCLIParser.parse(arguments: [
            "--show-hidden",
            "--skip-developer-folders",
            "--json", "scan.json",
            "/home/user"
        ])

        XCTAssertEqual(result, .run(LinuxCLIConfiguration(
            path: "/home/user",
            jsonOutput: "scan.json",
            csvOutput: nil,
            showHiddenFiles: true,
            skipDeveloperFolders: true
        )))
    }

    func testParserSupportsPathBeginningWithDashAfterSeparator() throws {
        let result = try LinuxCLIParser.parse(arguments: ["--", "-archive"])

        guard case .run(let configuration) = result else {
            return XCTFail("Expected a runnable configuration")
        }
        XCTAssertEqual(configuration.path, "-archive")
    }

    func testParserTreatsHelpAsAPathAfterSeparator() throws {
        let result = try LinuxCLIParser.parse(arguments: ["--", "--help"])

        guard case .run(let configuration) = result else {
            return XCTFail("Expected a runnable configuration")
        }
        XCTAssertEqual(configuration.path, "--help")
    }

    func testParserRejectsMultipleOutputs() {
        XCTAssertThrowsError(try LinuxCLIParser.parse(arguments: [
            "--json", "scan.json",
            "--csv", "scan.csv",
            "/tmp"
        ]))
    }

    func testParserRejectsUnsafeOptions() {
        XCTAssertThrowsError(try LinuxCLIParser.parse(arguments: ["--follow-symlinks", "/tmp"]))
        XCTAssertThrowsError(try LinuxCLIParser.parse(arguments: ["--compare", "old.json", "/tmp"]))
    }

    func testParserRejectsDuplicateOrOptionLikeOutputValues() {
        XCTAssertThrowsError(try LinuxCLIParser.parse(arguments: [
            "--json", "first.json", "--json", "second.json", "/tmp"
        ]))
        XCTAssertThrowsError(try LinuxCLIParser.parse(arguments: [
            "--json", "--follow-symlinks", "/tmp"
        ]))
    }

    func testCLIRejectsOutputInsideScannedDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("scan.json")

        let exitCode = await DiskInventoryZedCLI.execute(arguments: [
            "--json", output.path, root.path
        ])

        XCTAssertEqual(exitCode, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCLIPreservesFinalSymlinkForExporterRefusal() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let target = workspace.appendingPathComponent("target.json")
        let output = workspace.appendingPathComponent("output.json")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: target)

        let exitCode = await DiskInventoryZedCLI.execute(arguments: [
            "--json", output.path, source.path
        ])

        XCTAssertEqual(exitCode, 1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: output.path), target.path)
    }

    func testIncompleteScanDoesNotWriteExport() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let output = workspace.appendingPathComponent("scan.json")

        let directoryDescriptor = source.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        let invalidName = [CChar(bitPattern: 0xFF), CChar(0)]
        let fileDescriptor = invalidName.withUnsafeBufferPointer {
            openat(
                directoryDescriptor,
                $0.baseAddress!,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)
        close(fileDescriptor)
        defer {
            _ = invalidName.withUnsafeBufferPointer {
                unlinkat(directoryDescriptor, $0.baseAddress!, 0)
            }
            close(directoryDescriptor)
        }

        let exitCode = await DiskInventoryZedCLI.execute(arguments: [
            "--json", output.path, source.path
        ])

        XCTAssertEqual(exitCode, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCLIJSONRecordsEffectiveScanOptions() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let output = workspace.appendingPathComponent("scan.json")

        let exitCode = await DiskInventoryZedCLI.execute(arguments: [
            "--show-hidden",
            "--skip-developer-folders",
            "--json", output.path,
            source.path
        ])
        let snapshot = try ScanExporter.importSnapshot(from: output)

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(snapshot.schemaVersion, 4)
        XCTAssertEqual(snapshot.options, ScanOptions(
            skipDeveloperFolders: true,
            showHiddenFiles: true,
            showPackageContents: true,
            followSymlinks: false
        ))
    }

    func testCLIRefusesExistingDestinationBeforePublication() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let output = workspace.appendingPathComponent("scan.json")
        try Data("unchanged".utf8).write(to: output)

        let exitCode = await DiskInventoryZedCLI.execute(arguments: [
            "--json", output.path, source.path
        ])

        XCTAssertEqual(exitCode, 1)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "unchanged")
    }

    func testCLICancellationUsesInterruptExitCode() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootPath = root.path
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return await DiskInventoryZedCLI.execute(arguments: [rootPath])
        }
        let exitCode = await task.value

        XCTAssertEqual(exitCode, 130)
    }

    func testTerminalOutputEscapesControlsAndBidirectionalOverrides() {
        let unsafe = "safe\u{001B}[31m\nname\u{202E}txt"

        let escaped = DiskInventoryZedCLI.terminalSafe(unsafe)

        XCTAssertEqual(escaped, "safe\\u{001B}[31m\\u{000A}name\\u{202E}txt")
        XCTAssertFalse(escaped.contains("\u{001B}"))
        XCTAssertFalse(escaped.contains("\n"))
        XCTAssertFalse(escaped.contains("\u{202E}"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif
