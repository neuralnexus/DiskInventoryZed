// Disk Inventory Zed - read-only Linux command-line interface
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

#if os(Linux)
import Foundation
import Glibc

private let linuxCommandLineArguments = Array(CommandLine.arguments.dropFirst())

struct LinuxCLIConfiguration: Equatable {
    let path: String
    let jsonOutput: String?
    let csvOutput: String?
    let comparisonSnapshot: String?
    let showHiddenFiles: Bool
    let skipDeveloperFolders: Bool
    let followSymlinks: Bool
}

enum LinuxCLIParseResult: Equatable {
    case help
    case run(LinuxCLIConfiguration)
}

enum LinuxCLIParser {
    static func parse(arguments: [String]) throws -> LinuxCLIParseResult {
        var jsonOutput: String?
        var csvOutput: String?
        var comparisonSnapshot: String?
        var showHiddenFiles = false
        var skipDeveloperFolders = false
        var followSymlinks = false
        var paths: [String] = []
        var parsesOptions = true
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if parsesOptions && argument == "--" {
                parsesOptions = false
            } else if parsesOptions && (argument == "--help" || argument == "-h") {
                return .help
            } else if parsesOptions && argument == "--json" {
                jsonOutput = try value(after: argument, at: &index, in: arguments)
            } else if parsesOptions && argument == "--csv" {
                csvOutput = try value(after: argument, at: &index, in: arguments)
            } else if parsesOptions && argument == "--compare" {
                comparisonSnapshot = try value(after: argument, at: &index, in: arguments)
            } else if parsesOptions && argument == "--show-hidden" {
                showHiddenFiles = true
            } else if parsesOptions && argument == "--skip-developer-folders" {
                skipDeveloperFolders = true
            } else if parsesOptions && argument == "--follow-symlinks" {
                followSymlinks = true
            } else if parsesOptions && argument.hasPrefix("-") {
                throw LinuxCLIError.unknownOption(argument)
            } else {
                paths.append(argument)
            }
            index += 1
        }

        guard let path = paths.first else {
            throw LinuxCLIError.missingPath
        }
        guard paths.count == 1 else {
            throw LinuxCLIError.tooManyPaths
        }

        try validateDistinctFileRoles([
            ("--json", jsonOutput),
            ("--csv", csvOutput),
            ("--compare", comparisonSnapshot)
        ])

        return .run(LinuxCLIConfiguration(
            path: path,
            jsonOutput: jsonOutput,
            csvOutput: csvOutput,
            comparisonSnapshot: comparisonSnapshot,
            showHiddenFiles: showHiddenFiles,
            skipDeveloperFolders: skipDeveloperFolders,
            followSymlinks: followSymlinks
        ))
    }

    private static func value(
        after option: String,
        at index: inout Int,
        in arguments: [String]
    ) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw LinuxCLIError.missingValue(option)
        }
        return arguments[index]
    }

    private static func validateDistinctFileRoles(_ roles: [(String, String?)]) throws {
        var rolesByPath: [String: String] = [:]
        for (role, path) in roles {
            guard let path else { continue }
            let expandedPath = NSString(string: path).expandingTildeInPath
            let absolutePath = expandedPath.hasPrefix("/")
                ? expandedPath
                : FileManager.default.currentDirectoryPath + "/" + expandedPath
            let lexicalURL = URL(fileURLWithPath: absolutePath).standardizedFileURL
            let identity = fileRoleIdentity(for: lexicalURL)
            if let existingRole = rolesByPath[identity] {
                throw LinuxCLIError.conflictingPaths(existingRole, role)
            }
            rolesByPath[identity] = role
        }
    }

    private static func fileRoleIdentity(for url: URL) -> String {
        var entryStatus = stat()
        let entryResult = url.path.withCString { path in
            stat(path, &entryStatus)
        }
        if entryResult == 0 {
            return "entry|\(entryStatus.st_dev)|\(entryStatus.st_ino)"
        }

        let parentPath = url.deletingLastPathComponent().path
        var parentStatus = stat()
        let parentResult = parentPath.withCString { path in
            stat(path, &parentStatus)
        }
        if parentResult == 0 {
            let encodedName = Data(url.lastPathComponent.utf8).base64EncodedString()
            return "parent|\(parentStatus.st_dev)|\(parentStatus.st_ino)|\(encodedName)"
        }

        return parentPath.withCString { fileSystemPath in
            guard let resolvedPath = Glibc.realpath(fileSystemPath, nil) else {
                return "path|\(url.path)"
            }
            defer { Glibc.free(resolvedPath) }
            return "path|\(String(cString: resolvedPath))/\(url.lastPathComponent)"
        }
    }
}

enum LinuxCLIError: LocalizedError {
    case missingPath
    case tooManyPaths
    case missingValue(String)
    case unknownOption(String)
    case conflictingPaths(String, String)

    var errorDescription: String? {
        switch self {
        case .missingPath:
            return "A directory path is required."
        case .tooManyPaths:
            return "Only one directory can be scanned at a time."
        case .missingValue(let option):
            return "\(option) requires an output path."
        case .unknownOption(let option):
            return "Unknown option: \(option)"
        case .conflictingPaths(let first, let second):
            return "\(first) and \(second) must use different paths."
        }
    }
}

@main
struct DiskInventoryZedCLI {
    private static let usage = """
    Usage: DiskInventoryZed [options] PATH

    Scan a directory and report its logical and allocated disk usage. The Linux
    command-line interface is read-only and never deletes or moves files.

    Options:
      --json OUTPUT              Export a versioned JSON snapshot
      --csv OUTPUT               Export all entries as CSV
      --compare SNAPSHOT         Compare with an earlier JSON snapshot
      --show-hidden              Include hidden files and directories
      --skip-developer-folders   Skip .git, node_modules, .build, and similar folders
      --follow-symlinks          Follow symlinked directories with cycle protection
      -h, --help                 Show this help
    """

    static func main() async {
        let exitCode = await execute(arguments: linuxCommandLineArguments)
        if exitCode != 0 {
            Glibc.exit(exitCode)
        }
    }

    private static func execute(arguments: [String]) async -> Int32 {
        let parseResult: LinuxCLIParseResult
        do {
            parseResult = try LinuxCLIParser.parse(arguments: arguments)
        } catch {
            write("error: \(error.localizedDescription)\n\n\(usage)\n", to: .standardError)
            return 2
        }

        guard case .run(let configuration) = parseResult else {
            write(usage + "\n", to: .standardOutput)
            return 0
        }

        let displaysProgress = Glibc.isatty(STDERR_FILENO) == 1
        do {
            let sourceURL = fileURL(for: configuration.path)
            let options = ScanOptions(
                skipDeveloperFolders: configuration.skipDeveloperFolders,
                showHiddenFiles: configuration.showHiddenFiles,
                showPackageContents: true,
                followSymlinks: configuration.followSymlinks
            )
            let result = try await DiskScanner().scan(
                url: sourceURL,
                options: options
            ) { snapshot in
                guard displaysProgress else { return }
                write(
                    "\rScanning: \(snapshot.files) files, \(snapshot.directories) directories",
                    to: .standardError
                )
            }

            if displaysProgress {
                write("\n", to: .standardError)
            }

            let comparison: ScanComparison?
            if let path = configuration.comparisonSnapshot {
                let baseline = try ScanExporter.importSnapshot(from: fileURL(for: path))
                comparison = try ScanSnapshotComparator.compare(
                    current: result.root,
                    options: options,
                    diagnostics: result.diagnostics,
                    with: baseline
                )
            } else {
                comparison = nil
            }

            if let path = configuration.jsonOutput {
                try ScanExporter.exportJSON(
                    root: result.root,
                    diagnostics: result.diagnostics,
                    options: options,
                    to: fileURL(for: path)
                )
            }
            if let path = configuration.csvOutput {
                try ScanExporter.exportCSV(root: result.root, to: fileURL(for: path))
            }

            printSummary(result)
            if let comparison {
                printComparison(comparison)
            }
            if let path = configuration.jsonOutput {
                write("JSON snapshot: \(fileURL(for: path).path)\n", to: .standardOutput)
            }
            if let path = configuration.csvOutput {
                write("CSV export: \(fileURL(for: path).path)\n", to: .standardOutput)
            }
            return 0
        } catch {
            if displaysProgress {
                write("\n", to: .standardError)
            }
            write("error: \(error.localizedDescription)\n", to: .standardError)
            return 1
        }
    }

    private static func printSummary(_ result: DiskScanResult) {
        let diagnostics = result.diagnostics
        let summary = """
        Scanned: \(result.root.path)
        Files: \(result.totalFiles)
        Directories: \(result.totalDirectories)
        Logical size: \(formattedBytes(result.root.logicalSize)) (\(result.root.logicalSize) bytes)
        Allocated size: \(formattedBytes(result.root.allocatedSize)) (\(result.root.allocatedSize) bytes)
        Duration: \(String(format: "%.2f", result.duration)) seconds
        Issues: \(diagnostics.unreadableItems) unreadable, \(diagnostics.skippedDirectories) skipped, \(diagnostics.revisitedDirectories) revisited
        Links: \(diagnostics.symbolicLinks) symbolic, \(diagnostics.duplicateHardLinks) duplicate hard links
        """
        write(summary + "\n", to: .standardOutput)

        if !diagnostics.firstUnreadablePaths.isEmpty {
            write("First unreadable paths:\n", to: .standardOutput)
            for path in diagnostics.firstUnreadablePaths {
                write("  \(path)\n", to: .standardOutput)
            }
        }
    }

    private static func printComparison(_ comparison: ScanComparison) {
        let date = ISO8601DateFormatter().string(from: comparison.baselineDate)
        let delta = comparison.totalDelta > 0
            ? "+\(formattedBytes(comparison.totalDelta))"
            : formattedBytes(comparison.totalDelta)
        let summary = """

        Comparison with \(date):
        Total change: \(delta)
        Added: \(comparison.addedCount)
        Removed: \(comparison.removedCount)
        Changed: \(comparison.changedCount)
        """
        write(summary + "\n", to: .standardOutput)

        let changes = Array(comparison.largestGrowth.prefix(5)) +
            Array(comparison.largestShrinkage.prefix(5))
        if !changes.isEmpty {
            write("Largest changes:\n", to: .standardOutput)
            for change in changes {
                let changeSize = change.delta > 0
                    ? "+\(formattedBytes(change.delta))"
                    : formattedBytes(change.delta)
                write("  \(changeSize)  \(change.path)\n", to: .standardOutput)
            }
        }
    }

    private static func fileURL(for path: String) -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let absolutePath: String
        if expandedPath.hasPrefix("/") {
            absolutePath = expandedPath
        } else {
            absolutePath = FileManager.default.currentDirectoryPath + "/" + expandedPath
        }
        return URL(fileURLWithPath: absolutePath).standardizedFileURL
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func write(_ text: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
#endif
