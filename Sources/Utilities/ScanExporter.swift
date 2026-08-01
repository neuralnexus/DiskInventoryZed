// Disk Inventory Zed — scan export support
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

import Foundation

#if os(Linux)
import Glibc
private let linuxOTemporaryFile = Int32(0o20200000)
#endif

enum ScanExporter {
    private typealias AtomicWriter = (_ body: (FileHandle) throws -> Void) throws -> Void

#if os(Linux)
    private enum UnnamedTemporaryError: Error {
        case publicationUnavailable
    }
#endif

    /// Writes a reconstructable flat JSON document without first duplicating the entire
    /// in-memory tree. This keeps exports safe for scans containing millions of entries.
    static func exportJSON(root: FileNode, diagnostics: ScanDiagnostics, to url: URL) throws {
        try exportJSON(root: root, diagnostics: diagnostics) { body in
            try writeAtomically(to: url, body: body)
        }
    }

#if os(Linux)
    static func exportJSON(
        root: FileNode,
        diagnostics: ScanDiagnostics,
        to destination: LinuxExportDestination
    ) throws {
        try exportJSON(root: root, diagnostics: diagnostics) { body in
            try writeAtomicallyOnLinux(to: destination, body: body)
        }
    }
#endif

    private static func exportJSON(
        root: FileNode,
        diagnostics: ScanDiagnostics,
        writer: AtomicWriter
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        try writer { handle in
            let formatter = ISO8601DateFormatter()
            let encodedDiagnostics = try encoder.encode(JSONDiagnostics(diagnostics))
            let prefix = """
            {"schemaVersion":3,"exportedAt":\(jsonString(formatter.string(from: Date()))),"rootPath":\(jsonString(root.path)),"diagnostics":
            """
            try write(prefix, to: handle)
            try handle.write(contentsOf: encodedDiagnostics)
            try write(",\"entries\":[", to: handle)

            var stack: [(node: FileNode, parentPath: String?)] = [(root, nil)]
            var isFirst = true
            while let item = stack.popLast() {
                try Task.checkCancellation()
                if !isFirst { try write(",", to: handle) }
                isFirst = false

                let entry = JSONExportEntry(node: item.node, parentPath: item.parentPath)
                try handle.write(contentsOf: encoder.encode(entry))
                stack.append(contentsOf: item.node.children.reversed().map {
                    (node: $0, parentPath: item.node.path)
                })
            }

            try write("]}", to: handle)
        }
    }

    static func importSnapshot(from url: URL) throws -> ImportedScanSnapshot {
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        let document = try decoder.decode(JSONExportDocument.self, from: data)
        try Task.checkCancellation()
        guard (2...3).contains(document.schemaVersion) else {
            throw SnapshotImportError.unsupportedSchema(document.schemaVersion)
        }
        let rootEntry = try ScanSnapshotValidator.validate(
            entries: document.entries,
            declaredRootPath: document.rootPath,
            diagnostics: document.diagnostics.scanDiagnostics
        )

        return ImportedScanSnapshot(
            schemaVersion: document.schemaVersion,
            exportedAt: document.exportedAt,
            rootPath: document.rootPath ?? rootEntry.path,
            entries: document.entries,
            diagnostics: document.diagnostics.scanDiagnostics
        )
    }

    static func exportCSV(root: FileNode, to url: URL) throws {
        try exportCSV(root: root) { body in
            try writeAtomically(to: url, body: body)
        }
    }

#if os(Linux)
    static func exportCSV(root: FileNode, to destination: LinuxExportDestination) throws {
        try exportCSV(root: root) { body in
            try writeAtomicallyOnLinux(to: destination, body: body)
        }
    }
#endif

    private static func exportCSV(root: FileNode, writer: AtomicWriter) throws {
        try writer { handle in
            try write(
                "path,parent_path,name,kind,is_package,is_symbolic_link,allocated_bytes,logical_bytes,child_count,total_file_count,total_directory_count,created_at,modified_at,hard_link_duplicate,issue\n",
                to: handle
            )

            let formatter = ISO8601DateFormatter()
            var stack: [(node: FileNode, parentPath: String?)] = [(root, nil)]
            while let item = stack.popLast() {
                try Task.checkCancellation()
                let node = item.node
                let fields = [
                    csvField(node.path),
                    csvField(item.parentPath ?? ""),
                    csvField(node.displayName),
                    csvField(node.kind.rawValue),
                    node.isPackage ? "true" : "false",
                    node.isSymbolicLink ? "true" : "false",
                    String(node.allocatedSize),
                    String(node.logicalSize),
                    String(node.children.count),
                    String(node.totalFileCount),
                    String(node.totalDirectoryCount),
                    csvField(node.creationDate.map(formatter.string(from:)) ?? ""),
                    csvField(node.modificationDate.map(formatter.string(from:)) ?? ""),
                    node.isHardLinkDuplicate ? "true" : "false",
                    csvField(node.errorDescription ?? "")
                ]
                try write(fields.joined(separator: ",") + "\n", to: handle)
                stack.append(contentsOf: node.children.reversed().map {
                    (node: $0, parentPath: node.path)
                })
            }
        }
    }

    private static func writeAtomically(
        to destinationURL: URL,
        body: (FileHandle) throws -> Void
    ) throws {
#if os(Linux)
        let destination = try prepareLinuxDestination(
            for: destinationURL,
            excludingDirectoryIdentities: []
        )
        try writeAtomicallyOnLinux(to: destination, body: body)
#else
        let fileManager = FileManager.default
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")

        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            do {
                let handle = try FileHandle(forWritingTo: temporaryURL)
                defer { try? handle.close() }
                try body(handle)
                try handle.synchronize()
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
#endif
    }

#if os(Linux)
    static func prepareLinuxDestination(
        for destinationURL: URL,
        excludingDirectoryIdentities excludedIdentities: Set<String>
    ) throws -> LinuxExportDestination {
        let destinationName = destinationURL.lastPathComponent
        guard !destinationName.isEmpty, destinationName != ".", destinationName != ".." else {
            throw ScanExportError.invalidDestination(destinationURL.path)
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        let parentDescriptor = parentURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Glibc.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try validateDestinationParent(
                parentDescriptor,
                excludes: excludedIdentities,
                displayPath: destinationURL.path
            )
            return LinuxExportDestination(
                parentDescriptor: parentDescriptor,
                name: destinationName,
                displayPath: destinationURL.path,
                excludedDirectoryIdentities: excludedIdentities
            )
        } catch {
            Glibc.close(parentDescriptor)
            throw error
        }
    }

    private static func writeAtomicallyOnLinux(
        to destination: LinuxExportDestination,
        body: (FileHandle) throws -> Void
    ) throws {
        try validateDestinationParent(
            destination.parentDescriptor,
            excludes: destination.excludedDirectoryIdentities,
            displayPath: destination.displayPath
        )
        let unnamedDescriptor = Glibc.openat(
            destination.parentDescriptor,
            ".",
            O_WRONLY | linuxOTemporaryFile | O_CLOEXEC,
            mode_t(0o600)
        )
        if unnamedDescriptor >= 0 {
            do {
                try writeUnnamedTemporary(
                    descriptor: unnamedDescriptor,
                    to: destination,
                    body: body
                )
                return
            } catch is UnnamedTemporaryError {
                // Some systems allow O_TMPFILE but cannot publish it through procfs.
            }
        }
        if unnamedDescriptor < 0 {
            let unnamedError = errno
            guard unnamedError == EOPNOTSUPP ||
                    unnamedError == EINVAL ||
                    unnamedError == EISDIR ||
                    unnamedError == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: unnamedError) ?? .EIO)
            }
        }

        try validateDestinationParent(
            destination.parentDescriptor,
            excludes: destination.excludedDirectoryIdentities,
            displayPath: destination.displayPath
        )

        let stagingName = ".DiskInventoryZed-\(UUID().uuidString).tmp"
        let createStagingResult = stagingName.withCString { name in
            Glibc.mkdirat(destination.parentDescriptor, name, mode_t(0o700))
        }
        guard createStagingResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var stagingDescriptor: Int32 = -1
        defer {
            if stagingDescriptor >= 0 {
                Glibc.close(stagingDescriptor)
            }
            _ = stagingName.withCString { name in
                Glibc.unlinkat(destination.parentDescriptor, name, AT_REMOVEDIR)
            }
        }

        var createdStagingStatus = stat()
        let stagingStatusResult = stagingName.withCString { name in
            Glibc.fstatat(
                destination.parentDescriptor,
                name,
                &createdStagingStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard stagingStatusResult == 0,
              createdStagingStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              createdStagingStatus.st_uid == Glibc.geteuid() else {
            throw ScanExportError.invalidTemporaryFile
        }

        stagingDescriptor = stagingName.withCString { name in
            Glibc.openat(
                destination.parentDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard stagingDescriptor >= 0,
              Glibc.fchmod(stagingDescriptor, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var openedStagingStatus = stat()
        guard Glibc.fstat(stagingDescriptor, &openedStagingStatus) == 0,
              openedStagingStatus.st_dev == createdStagingStatus.st_dev,
              openedStagingStatus.st_ino == createdStagingStatus.st_ino else {
            throw ScanExportError.invalidTemporaryFile
        }

        let temporaryName = "export"
        let temporaryDescriptor = temporaryName.withCString { name in
            Glibc.openat(
                stagingDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var temporaryExists = true
        defer {
            if temporaryExists {
                _ = temporaryName.withCString { name in
                    Glibc.unlinkat(stagingDescriptor, name, 0)
                }
            }
        }

        guard Glibc.fchmod(temporaryDescriptor, mode_t(0o600)) == 0 else {
            Glibc.close(temporaryDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var temporaryStatus = stat()
        guard Glibc.fstat(temporaryDescriptor, &temporaryStatus) == 0,
              temporaryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              temporaryStatus.st_mode & mode_t(0o777) == mode_t(0o600) else {
            Glibc.close(temporaryDescriptor)
            throw ScanExportError.invalidTemporaryFile
        }

        let handle = FileHandle(fileDescriptor: temporaryDescriptor, closeOnDealloc: true)
        do {
            try body(handle)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try Task.checkCancellation()

        var destinationStatus = stat()
        try validateDestinationParent(
            destination.parentDescriptor,
            excludes: destination.excludedDirectoryIdentities,
            displayPath: destination.displayPath
        )
        let statusResult = destination.name.withCString { name in
            Glibc.fstatat(
                destination.parentDescriptor,
                name,
                &destinationStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if statusResult == 0 {
            if destinationStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw ScanExportError.symbolicLinkDestination(destination.displayPath)
            }
            throw ScanExportError.destinationExists(destination.displayPath)
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let linkResult = temporaryName.withCString { temporaryPath in
            destination.name.withCString { destinationPath in
                Glibc.linkat(
                    stagingDescriptor,
                    temporaryPath,
                    destination.parentDescriptor,
                    destinationPath,
                    0
                )
            }
        }
        guard linkResult == 0 else {
            if errno == EEXIST {
                throw ScanExportError.destinationExists(destination.displayPath)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try validateDestinationParent(
                destination.parentDescriptor,
                excludes: destination.excludedDirectoryIdentities,
                displayPath: destination.displayPath
            )
        } catch {
            removePublishedFileIfUnchanged(
                destination: destination,
                expectedStatus: temporaryStatus
            )
            throw error
        }

        _ = Glibc.fsync(destination.parentDescriptor)
        let unlinkResult = temporaryName.withCString { name in
            Glibc.unlinkat(stagingDescriptor, name, 0)
        }
        if unlinkResult == 0 {
            temporaryExists = false
        }
    }

    private static func writeUnnamedTemporary(
        descriptor: Int32,
        to destination: LinuxExportDestination,
        body: (FileHandle) throws -> Void
    ) throws {
        defer { Glibc.close(descriptor) }
        guard Glibc.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var temporaryStatus = stat()
        guard Glibc.fstat(descriptor, &temporaryStatus) == 0,
              temporaryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              temporaryStatus.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw ScanExportError.invalidTemporaryFile
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try body(handle)
        try handle.synchronize()
        try Task.checkCancellation()

        try validateDestinationParent(
            destination.parentDescriptor,
            excludes: destination.excludedDirectoryIdentities,
            displayPath: destination.displayPath
        )
        var destinationStatus = stat()
        let statusResult = destination.name.withCString { name in
            Glibc.fstatat(
                destination.parentDescriptor,
                name,
                &destinationStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if statusResult == 0 {
            if destinationStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw ScanExportError.symbolicLinkDestination(destination.displayPath)
            }
            throw ScanExportError.destinationExists(destination.displayPath)
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let descriptorPath = "/proc/self/fd/\(descriptor)"
        let linkResult = descriptorPath.withCString { sourcePath in
            destination.name.withCString { destinationPath in
                Glibc.linkat(
                    AT_FDCWD,
                    sourcePath,
                    destination.parentDescriptor,
                    destinationPath,
                    AT_SYMLINK_FOLLOW
                )
            }
        }
        guard linkResult == 0 else {
            if errno == EEXIST {
                throw ScanExportError.destinationExists(destination.displayPath)
            }
            if errno == ENOENT || errno == EPERM || errno == EACCES || errno == EXDEV {
                throw UnnamedTemporaryError.publicationUnavailable
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try validateDestinationParent(
                destination.parentDescriptor,
                excludes: destination.excludedDirectoryIdentities,
                displayPath: destination.displayPath
            )
        } catch {
            removePublishedFileIfUnchanged(
                destination: destination,
                expectedStatus: temporaryStatus
            )
            throw error
        }
        _ = Glibc.fsync(destination.parentDescriptor)
    }

    private static func removePublishedFileIfUnchanged(
        destination: LinuxExportDestination,
        expectedStatus: stat
    ) {
        var publishedStatus = stat()
        let publishedResult = destination.name.withCString { name in
            Glibc.fstatat(
                destination.parentDescriptor,
                name,
                &publishedStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if publishedResult == 0,
           publishedStatus.st_dev == expectedStatus.st_dev,
           publishedStatus.st_ino == expectedStatus.st_ino {
            _ = destination.name.withCString { name in
                Glibc.unlinkat(destination.parentDescriptor, name, 0)
            }
        }
    }

    private static func validateDestinationParent(
        _ parentDescriptor: Int32,
        excludes excludedIdentities: Set<String>,
        displayPath: String
    ) throws {
        guard !excludedIdentities.isEmpty else { return }
        var descriptor = Glibc.openat(
            parentDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Glibc.close(descriptor) }

        while true {
            var status = stat()
            guard Glibc.fstat(descriptor, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let identity = "\(status.st_dev)|\(status.st_ino)"
            if excludedIdentities.contains(identity) {
                throw ScanExportError.outputInsideScan(displayPath)
            }

            let parent = Glibc.openat(
                descriptor,
                "..",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard parent >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var parentStatus = stat()
            guard Glibc.fstat(parent, &parentStatus) == 0 else {
                let errorCode = errno
                Glibc.close(parent)
                throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
            }
            if parentStatus.st_dev == status.st_dev,
               parentStatus.st_ino == status.st_ino {
                Glibc.close(parent)
                break
            }

            Glibc.close(descriptor)
            descriptor = parent
        }
    }
#endif

    private static func write(_ string: String, to handle: FileHandle) throws {
        guard let data = string.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try handle.write(contentsOf: data)
    }

    private static func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

#if os(Linux)
final class LinuxExportDestination {
    let parentDescriptor: Int32
    let name: String
    let displayPath: String
    let excludedDirectoryIdentities: Set<String>

    init(
        parentDescriptor: Int32,
        name: String,
        displayPath: String,
        excludedDirectoryIdentities: Set<String>
    ) {
        self.parentDescriptor = parentDescriptor
        self.name = name
        self.displayPath = displayPath
        self.excludedDirectoryIdentities = excludedDirectoryIdentities
    }

    deinit {
        Glibc.close(parentDescriptor)
    }
}
#endif

enum ScanExportError: LocalizedError {
    case symbolicLinkDestination(String)
    case destinationExists(String)
    case invalidDestination(String)
    case invalidTemporaryFile
    case outputInsideScan(String)

    var errorDescription: String? {
        switch self {
        case .symbolicLinkDestination(let path):
            return "Refusing to replace symbolic-link export destination: \(path)"
        case .destinationExists(let path):
            return "Refusing to replace existing Linux export destination: \(path)"
        case .invalidDestination(let path):
            return "Invalid export destination: \(path)"
        case .invalidTemporaryFile:
            return "The private export staging file could not be verified."
        case .outputInsideScan(let path):
            return "Export output must be outside the scanned directory: \(path)"
        }
    }
}

enum SnapshotImportError: LocalizedError {
    case unsupportedSchema(Int)
    case missingRoot
    case invalidSnapshot(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Snapshot schema \(version) is not supported."
        case .missingRoot:
            return "The snapshot does not contain a root entry."
        case .invalidSnapshot(let reason):
            return "The snapshot is invalid: \(reason)."
        }
    }
}

struct JSONExportDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let rootPath: String?
    let diagnostics: JSONDiagnostics
    let entries: [JSONExportEntry]
}

struct JSONDiagnostics: Codable {
    let unreadableItems: Int
    let skippedDirectories: Int
    let symbolicLinks: Int
    let packages: Int
    let duplicateHardLinks: Int
    let revisitedDirectories: Int
    let firstUnreadablePaths: [String]

    init(_ diagnostics: ScanDiagnostics) {
        unreadableItems = diagnostics.unreadableItems
        skippedDirectories = diagnostics.skippedDirectories
        symbolicLinks = diagnostics.symbolicLinks
        packages = diagnostics.packages
        duplicateHardLinks = diagnostics.duplicateHardLinks
        revisitedDirectories = diagnostics.revisitedDirectories
        firstUnreadablePaths = diagnostics.firstUnreadablePaths
    }

    var scanDiagnostics: ScanDiagnostics {
        ScanDiagnostics(
            unreadableItems: unreadableItems,
            skippedDirectories: skippedDirectories,
            symbolicLinks: symbolicLinks,
            packages: packages,
            duplicateHardLinks: duplicateHardLinks,
            revisitedDirectories: revisitedDirectories,
            firstUnreadablePaths: firstUnreadablePaths
        )
    }

}

struct JSONExportEntry: Codable, Sendable {
    let path: String
    let parentPath: String?
    let name: String
    let kind: FileNode.Kind
    let isPackage: Bool
    let isSymbolicLink: Bool
    let allocatedSize: Int64
    let logicalSize: Int64
    let childCount: Int
    let totalFileCount: Int?
    let totalDirectoryCount: Int?
    let creationDate: Date?
    let modificationDate: Date?
    let isHardLinkDuplicate: Bool
    let issue: String?

    init(
        path: String,
        parentPath: String?,
        name: String,
        kind: FileNode.Kind,
        isPackage: Bool,
        isSymbolicLink: Bool,
        allocatedSize: Int64,
        logicalSize: Int64,
        childCount: Int,
        totalFileCount: Int? = nil,
        totalDirectoryCount: Int? = nil,
        creationDate: Date?,
        modificationDate: Date?,
        isHardLinkDuplicate: Bool,
        issue: String?
    ) {
        self.path = path
        self.parentPath = parentPath
        self.name = name
        self.kind = kind
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.childCount = childCount
        self.totalFileCount = totalFileCount
        self.totalDirectoryCount = totalDirectoryCount
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.isHardLinkDuplicate = isHardLinkDuplicate
        self.issue = issue
    }

    init(node: FileNode, parentPath: String?) {
        self.init(
            path: node.path,
            parentPath: parentPath,
            name: node.displayName,
            kind: node.kind,
            isPackage: node.isPackage,
            isSymbolicLink: node.isSymbolicLink,
            allocatedSize: node.allocatedSize,
            logicalSize: node.logicalSize,
            childCount: node.children.count,
            totalFileCount: node.totalFileCount,
            totalDirectoryCount: node.totalDirectoryCount,
            creationDate: node.creationDate,
            modificationDate: node.modificationDate,
            isHardLinkDuplicate: node.isHardLinkDuplicate,
            issue: node.errorDescription
        )
    }
}
