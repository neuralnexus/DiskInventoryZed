#if os(Linux)
import Foundation
import Glibc
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
            Glibc.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        let invalidName = [CChar(bitPattern: 0xFF), CChar(0)]
        let fileDescriptor = invalidName.withUnsafeBufferPointer {
            Glibc.openat(
                directoryDescriptor,
                $0.baseAddress!,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)
        Glibc.close(fileDescriptor)
        defer {
            _ = invalidName.withUnsafeBufferPointer {
                Glibc.unlinkat(directoryDescriptor, $0.baseAddress!, 0)
            }
            Glibc.close(directoryDescriptor)
        }

        let exitCode = await DiskInventoryZedCLI.execute(arguments: [
            "--json", output.path, source.path
        ])

        XCTAssertEqual(exitCode, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif
