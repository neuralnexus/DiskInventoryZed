// Disk Inventory Zed - read-only Linux command-line interface
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

#if os(Linux)
import Foundation
import Glibc

private let linuxCommandLineArguments = Array(ProcessInfo.processInfo.arguments.dropFirst())

struct LinuxCLIConfiguration: Equatable {
    let path: String
    let jsonOutput: String?
    let csvOutput: String?
    let showHiddenFiles: Bool
    let skipDeveloperFolders: Bool
}

enum LinuxCLIParseResult: Equatable {
    case help
    case run(LinuxCLIConfiguration)
}

enum LinuxCLIParser {
    static func parse(arguments: [String]) throws -> LinuxCLIParseResult {
        var jsonOutput: String?
        var csvOutput: String?
        var showHiddenFiles = false
        var skipDeveloperFolders = false
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
                guard jsonOutput == nil else { throw LinuxCLIError.duplicateOption(argument) }
                jsonOutput = try value(after: argument, at: &index, in: arguments)
            } else if parsesOptions && argument == "--csv" {
                guard csvOutput == nil else { throw LinuxCLIError.duplicateOption(argument) }
                csvOutput = try value(after: argument, at: &index, in: arguments)
            } else if parsesOptions && argument == "--show-hidden" {
                showHiddenFiles = true
            } else if parsesOptions && argument == "--skip-developer-folders" {
                skipDeveloperFolders = true
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
        guard jsonOutput == nil || csvOutput == nil else {
            throw LinuxCLIError.multipleOutputs
        }

        return .run(LinuxCLIConfiguration(
            path: path,
            jsonOutput: jsonOutput,
            csvOutput: csvOutput,
            showHiddenFiles: showHiddenFiles,
            skipDeveloperFolders: skipDeveloperFolders
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
        let value = arguments[index]
        guard !value.hasPrefix("-") else {
            throw LinuxCLIError.missingValue(option)
        }
        return value
    }
}

enum LinuxCLIError: LocalizedError {
    case missingPath
    case tooManyPaths
    case missingValue(String)
    case unknownOption(String)
    case duplicateOption(String)
    case multipleOutputs

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
        case .duplicateOption(let option):
            return "\(option) can only be specified once."
        case .multipleOutputs:
            return "Only one of --json or --csv can be used per scan."
        }
    }
}

private enum LinuxCLIRuntimeError: LocalizedError {
    case invalidFileSystemPath(String)
    case outputInsideScan(String)

    var errorDescription: String? {
        switch self {
        case .invalidFileSystemPath(let path):
            return "The file-system path could not be resolved: \(path)"
        case .outputInsideScan(let path):
            return "Export output must be outside the scanned directory: \(path)"
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
      --show-hidden              Include hidden files and directories
      --skip-developer-folders   Skip .git, node_modules, .build, and similar folders
      -h, --help                 Show this help

    Symlinks are listed but never followed. Use one export option per scan;
    the output must be outside PATH and must not already exist.
    """

    static func main() async {
        let exitCode = await execute(arguments: linuxCommandLineArguments)
        if exitCode != 0 {
            Glibc.exit(exitCode)
        }
    }

    static func execute(arguments: [String]) async -> Int32 {
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
            try validateOutputLocation(configuration.jsonOutput, relativeTo: sourceURL)
            try validateOutputLocation(configuration.csvOutput, relativeTo: sourceURL)
            let options = ScanOptions(
                skipDeveloperFolders: configuration.skipDeveloperFolders,
                showHiddenFiles: configuration.showHiddenFiles,
                showPackageContents: true,
                followSymlinks: false
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

            guard result.diagnostics.unreadableItems == 0,
                  result.diagnostics.revisitedDirectories == 0 else {
                printSummary(result)
                write(
                    "error: Scan was incomplete; no export was written.\n",
                    to: .standardError
                )
                return 1
            }

            if let path = configuration.jsonOutput {
                let destination = try ScanExporter.prepareLinuxDestination(
                    for: fileURL(for: path),
                    excludingDirectoryIdentities: result.scannedDirectoryIdentities
                )
                try ScanExporter.exportJSON(
                    root: result.root,
                    diagnostics: result.diagnostics,
                    to: destination
                )
            }
            if let path = configuration.csvOutput {
                let destination = try ScanExporter.prepareLinuxDestination(
                    for: fileURL(for: path),
                    excludingDirectoryIdentities: result.scannedDirectoryIdentities
                )
                try ScanExporter.exportCSV(root: result.root, to: destination)
            }

            printSummary(result)
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

    private static func fileURL(for path: String) -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let absolutePath: String
        if expandedPath.hasPrefix("/") {
            absolutePath = expandedPath
        } else {
            absolutePath = FileManager.default.currentDirectoryPath + "/" + expandedPath
        }
        return URL(fileURLWithPath: absolutePath)
    }

    private static func validateOutputLocation(_ output: String?, relativeTo sourceURL: URL) throws {
        guard let output else { return }

        let scanPath = try resolvedPath(sourceURL.path)
        let outputURL = fileURL(for: output)
        let outputParent = try resolvedPath(outputURL.deletingLastPathComponent().path)
        let outputPath = outputParent == "/"
            ? "/\(outputURL.lastPathComponent)"
            : "\(outputParent)/\(outputURL.lastPathComponent)"

        guard !isSameOrDescendant(outputPath, of: scanPath) else {
            throw LinuxCLIRuntimeError.outputInsideScan(outputURL.path)
        }
    }

    private static func resolvedPath(_ path: String) throws -> String {
        try path.withCString { fileSystemPath in
            guard let resolved = Glibc.realpath(fileSystemPath, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { Glibc.free(resolved) }
            guard let value = String(validatingUTF8: resolved) else {
                throw LinuxCLIRuntimeError.invalidFileSystemPath(path)
            }
            return value
        }
    }

    private static func isSameOrDescendant(_ path: String, of directory: String) -> Bool {
        if directory == "/" { return path.hasPrefix("/") }
        return path == directory || path.hasPrefix(directory + "/")
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func write(_ text: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
#endif
