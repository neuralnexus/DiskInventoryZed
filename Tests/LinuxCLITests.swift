#if os(Linux)
import XCTest
@testable import DiskInventoryZed

final class LinuxCLITests: XCTestCase {
    func testParserBuildsScanConfiguration() throws {
        let result = try LinuxCLIParser.parse(arguments: [
            "--show-hidden",
            "--skip-developer-folders",
            "--follow-symlinks",
            "--json", "scan.json",
            "--csv", "scan.csv",
            "--compare", "old.json",
            "/home/user"
        ])

        XCTAssertEqual(result, .run(LinuxCLIConfiguration(
            path: "/home/user",
            jsonOutput: "scan.json",
            csvOutput: "scan.csv",
            comparisonSnapshot: "old.json",
            showHiddenFiles: true,
            skipDeveloperFolders: true,
            followSymlinks: true
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

    func testParserRejectsConflictingFileRoles() {
        XCTAssertThrowsError(try LinuxCLIParser.parse(arguments: [
            "--json", "./scan.out",
            "--csv", "scan.out",
            "/tmp"
        ]))
    }

    func testParserRejectsFileRolesThroughSymlinkedParents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedCLIPathTests-\(UUID().uuidString)", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)

        XCTAssertThrowsError(try LinuxCLIParser.parse(arguments: [
            "--json", realDirectory.appendingPathComponent("scan.out").path,
            "--csv", aliasDirectory.appendingPathComponent("scan.out").path,
            "/tmp"
        ]))
    }

    func testParserRejectsFileRolesThroughFinalSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskInventoryZedCLIFinalLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("baseline.json")
        let alias = root.appendingPathComponent("alias.json")
        try Data("snapshot".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        XCTAssertThrowsError(try LinuxCLIParser.parse(arguments: [
            "--compare", alias.path,
            "--csv", target.path,
            "/tmp"
        ]))
    }

    func testParserRejectsUnknownOption() {
        XCTAssertThrowsError(try LinuxCLIParser.parse(arguments: ["--delete", "/tmp"]))
    }
}
#endif
