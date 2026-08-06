// Disk Inventory Zed - read-only Linux command-line interface
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

#if os(Linux)
import Dispatch
import Foundation
import CLinuxSignals
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("A supported Linux C library is required")
#endif

private let linuxCommandLineArguments = Array(ProcessInfo.processInfo.arguments.dropFirst())

private final class LinuxSignalState: @unchecked Sendable {
    private let lock = NSLock()
    private var signalExitCode: Int32?
    private var commandTask: Task<Int32, Never>?

    func handle(_ signalNumber: Int32) {
        lock.lock()
        guard signalExitCode == nil else {
            lock.unlock()
            return
        }
        signalExitCode = 128 + signalNumber
        let task = commandTask
        lock.unlock()
        task?.cancel()
    }

    func register(_ task: Task<Int32, Never>) {
        lock.lock()
        commandTask = task
        let shouldCancel = signalExitCode != nil
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }
}

struct LinuxCLIConfiguration: Equatable {
    let path: String
    let jsonOutput: String?
    let csvOutput: String?
    let showHiddenFiles: Bool
    let skipDeveloperFolders: Bool
}

enum LinuxCLIParseResult: Equatable {
    case help
    case version
    case run(LinuxCLIConfiguration)
}

enum LinuxCLIParser {
    static func parse(arguments: [String]) throws -> LinuxCLIParseResult {
        var jsonOutput: String?
        var csvOutput: String?
        var showHiddenFiles = true
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
            } else if parsesOptions && argument == "--version" {
                return .version
            } else if parsesOptions && argument == "--json" {
                guard jsonOutput == nil else { throw LinuxCLIError.duplicateOption(argument) }
                jsonOutput = try value(after: argument, at: &index, in: arguments)
            } else if parsesOptions && argument == "--csv" {
                guard csvOutput == nil else { throw LinuxCLIError.duplicateOption(argument) }
                csvOutput = try value(after: argument, at: &index, in: arguments)
            } else if parsesOptions && argument == "--exclude-hidden" {
                showHiddenFiles = false
            } else if parsesOptions && argument == "--skip-developer-folders" {
                skipDeveloperFolders = true
            } else if parsesOptions && argument.hasPrefix("-") {
                throw LinuxCLIError.unknownOption(argument)
            } else {
                paths.append(argument)
            }
            index += 1
        }

        guard let path = paths.first, !path.isEmpty else {
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
        guard !value.isEmpty, !value.hasPrefix("-") else {
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

private enum PreparedLinuxExport {
    case json(path: String, destination: LinuxExportDestination)
    case csv(path: String, destination: LinuxExportDestination)

    var path: String {
        switch self {
        case .json(let path, _), .csv(let path, _):
            return path
        }
    }

    var destination: LinuxExportDestination {
        switch self {
        case .json(_, let destination), .csv(_, let destination):
            return destination
        }
    }
}

@main
struct DiskInventoryZedCLI {
    static let version = "1.2"

    private static let usage = """
    Usage: DiskInventoryZed [options] PATH

    Scan a directory and report its logical and allocated disk usage. The Linux
    command-line interface is read-only and never deletes or moves files.

    Options:
      --json OUTPUT              Export a versioned JSON snapshot
      --csv OUTPUT               Export all entries as CSV
      --exclude-hidden           Exclude hidden files and directories
      --skip-developer-folders   Skip .git, node_modules, .build, and similar folders
      --version                  Show the installed version
      -h, --help                 Show this help

    Symlinks are listed but never followed. Use one export option per scan;
    the output must be outside PATH and must not already exist.

    Copyright (C) 2026 Matt Ivan. GPL-3.0-or-later; absolutely no warranty.
    License: https://github.com/neuralnexus/DiskInventoryZed/blob/v\(version)/LICENSE
    """

    static func main() async {
        var signalDescriptors = [Int32](repeating: -1, count: 2)
        let installResult = signalDescriptors.withUnsafeMutableBufferPointer { descriptors in
            diz_install_signal_pipe(descriptors.baseAddress)
        }
        guard installResult == 0 else {
            try? write("error: Could not install signal handlers.\n", to: .standardError)
            exit(1)
        }
        let signalReadDescriptor = signalDescriptors[0]
        let signalQueue = DispatchQueue(label: "DiskInventoryZed.signals")
        let signalSource = DispatchSource.makeReadSource(
            fileDescriptor: signalReadDescriptor,
            queue: signalQueue
        )
        let signalState = LinuxSignalState()
        signalSource.setEventHandler {
            while true {
                var signalNumber: Int32 = 0
                let readCount = withUnsafeMutableBytes(of: &signalNumber) { buffer in
                    read(signalReadDescriptor, buffer.baseAddress, buffer.count)
                }
                if readCount == MemoryLayout<Int32>.size {
                    signalState.handle(signalNumber)
                    continue
                }
                if readCount < 0 && errno == EINTR {
                    continue
                }
                break
            }
        }
        signalSource.resume()
        let commandTask = Task {
            await execute(arguments: linuxCommandLineArguments)
        }
        signalState.register(commandTask)
        let commandExitCode = await commandTask.value
        signalSource.cancel()
        let signalBeforeFinish = diz_received_signal()
        if signalBeforeFinish != 0, commandExitCode == 0 {
            try? write(
                "error: Operation was interrupted after completion; verify whether the requested export was published.\n",
                to: .standardError
            )
        }
        let receivedSignal = diz_finish_signal_pipe()
        let exitCode = receivedSignal == 0 ? commandExitCode : 128 + receivedSignal
        if exitCode != 0 {
            exit(exitCode)
        }
    }

    static func execute(arguments: [String]) async -> Int32 {
        let parseResult: LinuxCLIParseResult
        do {
            parseResult = try LinuxCLIParser.parse(arguments: arguments)
        } catch {
            try? write(
                "error: \(terminalSafe(error.localizedDescription))\n\n\(usage)\n",
                to: .standardError
            )
            return 2
        }

        switch parseResult {
        case .help:
            do {
                try write(usage + "\n", to: .standardOutput)
                return 0
            } catch {
                return 1
            }
        case .version:
            do {
                try write("DiskInventoryZed \(version)\n", to: .standardOutput)
                return 0
            } catch {
                return 1
            }
        case .run(let configuration):
            return await run(configuration)
        }
    }

    private static func run(_ configuration: LinuxCLIConfiguration) async -> Int32 {
        let displaysProgress = isatty(STDERR_FILENO) == 1
        do {
            let sourceURL = fileURL(for: configuration.path)
            try validateOutputLocation(configuration.jsonOutput, relativeTo: sourceURL)
            try validateOutputLocation(configuration.csvOutput, relativeTo: sourceURL)
            let preparedExport = try prepareExport(configuration)
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
                try? write(
                    "\rScanning: \(snapshot.files) files, \(snapshot.directories) directories",
                    to: .standardError
                )
            }

            if displaysProgress {
                try write("\n", to: .standardError)
            }

            guard result.diagnostics.unreadableItems == 0,
                  result.diagnostics.revisitedDirectories == 0 else {
                try printSummary(result)
                try write(
                    "error: Scan was incomplete; no export was written.\n",
                    to: .standardError
                )
                return 1
            }

            if let preparedExport {
                try ScanExporter.restrictLinuxDestination(
                    preparedExport.destination,
                    excludingDirectoryIdentities: result.scannedDirectoryIdentities
                )
            }
            if displaysProgress, let preparedExport {
                let format: String
                switch preparedExport {
                case .json:
                    format = "JSON"
                case .csv:
                    format = "CSV"
                }
                try write("Exporting \(format)...\n", to: .standardError)
            }
            switch preparedExport {
            case .json(_, let destination):
                try ScanExporter.exportJSON(
                    root: result.root,
                    diagnostics: result.diagnostics,
                    options: options,
                    to: destination
                )
            case .csv(_, let destination):
                try ScanExporter.exportCSV(root: result.root, to: destination)
            case nil:
                break
            }

            try printSummary(result)
            switch preparedExport {
            case .json(let path, _):
                try write(
                    "JSON snapshot: \(terminalSafe(fileURL(for: path).path))\n",
                    to: .standardOutput
                )
            case .csv(let path, _):
                try write(
                    "CSV export: \(terminalSafe(fileURL(for: path).path))\n",
                    to: .standardOutput
                )
            case nil:
                break
            }
            return 0
        } catch is CancellationError {
            if displaysProgress {
                try? write("\n", to: .standardError)
            }
            try? write("error: Operation cancelled.\n", to: .standardError)
            return 130
        } catch {
            if displaysProgress {
                try? write("\n", to: .standardError)
            }
            try? write(
                "error: \(terminalSafe(error.localizedDescription))\n",
                to: .standardError
            )
            return 1
        }
    }

    private static func printSummary(_ result: DiskScanResult) throws {
        let diagnostics = result.diagnostics
        let summary = """
        Scanned: \(terminalSafe(result.root.path))
        Files: \(result.totalFiles)
        Directories: \(result.totalDirectories)
        Logical size: \(formattedBytes(result.root.logicalSize)) (\(result.root.logicalSize) bytes)
        Allocated size: \(formattedBytes(result.root.allocatedSize)) (\(result.root.allocatedSize) bytes)
        Duration: \(String(format: "%.2f", result.duration)) seconds
        Issues: \(diagnostics.unreadableItems) unreadable, \(diagnostics.skippedDirectories) skipped, \(diagnostics.revisitedDirectories) revisited
        Links: \(diagnostics.symbolicLinks) symbolic, \(diagnostics.duplicateHardLinks) duplicate hard links
        """
        try write(summary + "\n", to: .standardOutput)

        if !diagnostics.firstUnreadablePaths.isEmpty {
            var unreadableReasons: [Data: String] = [:]
            let wantedPaths = Set(diagnostics.firstUnreadablePaths.map { Data($0.utf8) })
            var stack = [result.root]
            while let node = stack.popLast(), unreadableReasons.count < wantedPaths.count {
                let pathKey = Data(node.path.utf8)
                if wantedPaths.contains(pathKey), let reason = node.errorDescription {
                    unreadableReasons[pathKey] = reason
                }
                stack.append(contentsOf: node.children)
            }
            try write("First unreadable paths:\n", to: .standardOutput)
            for path in diagnostics.firstUnreadablePaths {
                let reason = unreadableReasons[Data(path.utf8)].map {
                    ": \(terminalSafe($0))"
                } ?? ""
                try write("  \(terminalSafe(path))\(reason)\n", to: .standardOutput)
            }
        }
    }

    private static func prepareExport(
        _ configuration: LinuxCLIConfiguration
    ) throws -> PreparedLinuxExport? {
        if let path = configuration.jsonOutput {
            return .json(
                path: path,
                destination: try ScanExporter.prepareLinuxDestination(
                    for: fileURL(for: path),
                    excludingDirectoryIdentities: []
                )
            )
        }
        if let path = configuration.csvOutput {
            return .csv(
                path: path,
                destination: try ScanExporter.prepareLinuxDestination(
                    for: fileURL(for: path),
                    excludingDirectoryIdentities: []
                )
            )
        }
        return nil
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
            guard let resolved = realpath(fileSystemPath, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
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

    static func terminalSafe(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                result += String(format: "\\u{%04X}", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func write(_ text: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data(text.utf8))
    }
}
#endif
