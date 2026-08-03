// Disk Inventory Zed — scan export support
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

import Foundation

#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("A supported Linux C library is required")
#endif
private let linuxOTemporaryFile = Int32(0o20200000)
#else
import Darwin
#endif

enum ScanExporter {
    private typealias AtomicWriter = (_ body: (FileHandle) throws -> Void) throws -> Void
    static let maximumSnapshotBytes = 256 * 1_024 * 1_024
    static let maximumSnapshotEntries = 1_000_000
    static let maximumSnapshotPathBytes = 16 * 1_024
    static let maximumSnapshotIssueBytes = 64 * 1_024

#if os(Linux)
    private enum UnnamedTemporaryError: Error {
        case publicationUnavailable
    }
#endif

    /// Writes a reconstructable flat JSON document without first duplicating the entire
    /// in-memory tree. This keeps exports safe for scans containing millions of entries.
    static func exportJSON(
        root: FileNode,
        diagnostics: ScanDiagnostics,
        options: ScanOptions = .default,
        to url: URL
    ) throws {
        try exportJSON(root: root, diagnostics: diagnostics, options: options) { body in
            try writeAtomically(to: url, body: body)
        }
    }

#if os(Linux)
    static func exportJSON(
        root: FileNode,
        diagnostics: ScanDiagnostics,
        options: ScanOptions = .default,
        to destination: LinuxExportDestination
    ) throws {
        try exportJSON(root: root, diagnostics: diagnostics, options: options) { body in
            try writeAtomicallyOnLinux(to: destination, body: body)
        }
    }
#endif

    private static func exportJSON(
        root: FileNode,
        diagnostics: ScanDiagnostics,
        options: ScanOptions,
        writer: AtomicWriter
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard diagnostics.firstUnreadablePaths.count <= 20 else {
            throw SnapshotImportError.resourceLimitExceeded(
                "snapshots may contain at most 20 unreadable-path examples"
            )
        }
        for path in diagnostics.firstUnreadablePaths {
            try validateSnapshotPathLength(path)
        }

        try writer { handle in
            var bytesWritten = 0
            let formatter = ISO8601DateFormatter()
            let encodedDiagnostics = try encoder.encode(JSONDiagnostics(diagnostics))
            let encodedOptions = try encoder.encode(options)
            let prefix = """
            {"schemaVersion":4,"exportedAt":\(jsonString(formatter.string(from: Date()))),"rootPath":\(jsonString(root.path)),"diagnostics":
            """
            try writeSnapshot(prefix, to: handle, bytesWritten: &bytesWritten)
            try writeSnapshot(encodedDiagnostics, to: handle, bytesWritten: &bytesWritten)
            try writeSnapshot(",\"options\":", to: handle, bytesWritten: &bytesWritten)
            try writeSnapshot(encodedOptions, to: handle, bytesWritten: &bytesWritten)
            try writeSnapshot(",\"entries\":[", to: handle, bytesWritten: &bytesWritten)

            var isFirst = true
            try traverse(root: root) { node, parentPath in
                try validateSnapshotPathLength(node.path)
                try validateSnapshotPathLength(node.displayName)
                if let issue = node.errorDescription,
                   issue.utf8.count > maximumSnapshotIssueBytes {
                    throw SnapshotImportError.resourceLimitExceeded(
                        "entry issue text may be at most \(maximumSnapshotIssueBytes) UTF-8 bytes"
                    )
                }
                if !isFirst {
                    try writeSnapshot(",", to: handle, bytesWritten: &bytesWritten)
                }
                isFirst = false

                let entry = JSONExportEntry(node: node, parentPath: parentPath)
                try writeSnapshot(
                    encoder.encode(entry),
                    to: handle,
                    bytesWritten: &bytesWritten
                )
            }

            try writeSnapshot("]}", to: handle, bytesWritten: &bytesWritten)
        }
    }

    static func importSnapshot(from url: URL) throws -> ImportedScanSnapshot {
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try readSnapshotData(from: url)
        try Task.checkCancellation()
        let document = try decoder.decode(JSONExportDocument.self, from: data)
        try Task.checkCancellation()
        guard (2...4).contains(document.schemaVersion) else {
            throw SnapshotImportError.unsupportedSchema(document.schemaVersion)
        }
        guard document.entries.count <= maximumSnapshotEntries else {
            throw SnapshotImportError.resourceLimitExceeded(
                "snapshots may contain at most \(maximumSnapshotEntries) entries"
            )
        }
        if document.schemaVersion == 4, document.options == nil {
            throw SnapshotImportError.invalidSnapshot("schema 4 requires scan options")
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
            diagnostics: document.diagnostics.scanDiagnostics,
            options: document.options,
            isValidated: true
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
            try traverse(root: root) { node, parentPath in
                let fields = [
                    csvField(node.path),
                    csvField(parentPath ?? ""),
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
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
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
            try validateDestinationAvailability(
                parentDescriptor: parentDescriptor,
                name: destinationName,
                displayPath: destinationURL.path
            )
            return LinuxExportDestination(
                parentDescriptor: parentDescriptor,
                name: destinationName,
                displayPath: destinationURL.path,
                excludedDirectoryIdentities: excludedIdentities
            )
        } catch {
            close(parentDescriptor)
            throw error
        }
    }

    static func restrictLinuxDestination(
        _ destination: LinuxExportDestination,
        excludingDirectoryIdentities excludedIdentities: Set<String>
    ) throws {
        let combinedIdentities = destination.excludedDirectoryIdentities.union(excludedIdentities)
        try validateDestinationParent(
            destination.parentDescriptor,
            excludes: combinedIdentities,
            displayPath: destination.displayPath
        )
        destination.excludedDirectoryIdentities = combinedIdentities
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
        let unnamedDescriptor = openat(
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
            mkdirat(destination.parentDescriptor, name, mode_t(0o700))
        }
        guard createStagingResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var stagingDescriptor: Int32 = -1
        defer {
            if stagingDescriptor >= 0 {
                close(stagingDescriptor)
            }
            _ = stagingName.withCString { name in
                unlinkat(destination.parentDescriptor, name, AT_REMOVEDIR)
            }
        }

        var createdStagingStatus = stat()
        let stagingStatusResult = stagingName.withCString { name in
            fstatat(
                destination.parentDescriptor,
                name,
                &createdStagingStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard stagingStatusResult == 0,
              createdStagingStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              createdStagingStatus.st_uid == geteuid() else {
            throw ScanExportError.invalidTemporaryFile
        }

        stagingDescriptor = stagingName.withCString { name in
            openat(
                destination.parentDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard stagingDescriptor >= 0,
              fchmod(stagingDescriptor, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var openedStagingStatus = stat()
        guard fstat(stagingDescriptor, &openedStagingStatus) == 0,
              openedStagingStatus.st_dev == createdStagingStatus.st_dev,
              openedStagingStatus.st_ino == createdStagingStatus.st_ino else {
            throw ScanExportError.invalidTemporaryFile
        }

        let temporaryName = "export"
        let temporaryDescriptor = temporaryName.withCString { name in
            openat(
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
                    unlinkat(stagingDescriptor, name, 0)
                }
            }
        }

        guard fchmod(temporaryDescriptor, mode_t(0o600)) == 0 else {
            close(temporaryDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var temporaryStatus = stat()
        guard fstat(temporaryDescriptor, &temporaryStatus) == 0,
              temporaryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              temporaryStatus.st_mode & mode_t(0o777) == mode_t(0o600) else {
            close(temporaryDescriptor)
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
            fstatat(
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
                linkat(
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
        var publicationCommitted = false
        defer {
            if !publicationCommitted {
                removePublishedFileIfUnchanged(
                    destination: destination,
                    expectedStatus: temporaryStatus
                )
            }
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

        _ = fsync(destination.parentDescriptor)
        let unlinkResult = temporaryName.withCString { name in
            unlinkat(stagingDescriptor, name, 0)
        }
        if unlinkResult == 0 {
            temporaryExists = false
        }
        try Task.checkCancellation()
        publicationCommitted = true
    }

    private static func writeUnnamedTemporary(
        descriptor: Int32,
        to destination: LinuxExportDestination,
        body: (FileHandle) throws -> Void
    ) throws {
        defer { close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var temporaryStatus = stat()
        guard fstat(descriptor, &temporaryStatus) == 0,
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
            fstatat(
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
                linkat(
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
        var publicationCommitted = false
        defer {
            if !publicationCommitted {
                removePublishedFileIfUnchanged(
                    destination: destination,
                    expectedStatus: temporaryStatus
                )
            }
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
        _ = fsync(destination.parentDescriptor)
        try Task.checkCancellation()
        publicationCommitted = true
    }

    private static func removePublishedFileIfUnchanged(
        destination: LinuxExportDestination,
        expectedStatus: stat
    ) {
        var publishedStatus = stat()
        let publishedResult = destination.name.withCString { name in
            fstatat(
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
                unlinkat(destination.parentDescriptor, name, 0)
            }
        }
    }

    private static func validateDestinationParent(
        _ parentDescriptor: Int32,
        excludes excludedIdentities: Set<String>,
        displayPath: String
    ) throws {
        var descriptor = openat(
            parentDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        while true {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let ownerIsTrusted = status.st_uid == geteuid() || status.st_uid == 0
            let writableByOthers = status.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
            let hasStickyBit = status.st_mode & mode_t(S_ISVTX) != 0
            guard ownerIsTrusted, !writableByOthers || hasStickyBit else {
                throw ScanExportError.untrustedDestinationParent(displayPath)
            }
            let identity = "\(status.st_dev)|\(status.st_ino)"
            if excludedIdentities.contains(identity) {
                throw ScanExportError.outputInsideScan(displayPath)
            }

            let parent = openat(
                descriptor,
                "..",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard parent >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var parentStatus = stat()
            guard fstat(parent, &parentStatus) == 0 else {
                let errorCode = errno
                close(parent)
                throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
            }
            if parentStatus.st_dev == status.st_dev,
               parentStatus.st_ino == status.st_ino {
                close(parent)
                break
            }

            close(descriptor)
            descriptor = parent
        }
    }

    private static func validateDestinationAvailability(
        parentDescriptor: Int32,
        name: String,
        displayPath: String
    ) throws {
        var destinationStatus = stat()
        let statusResult = name.withCString { path in
            fstatat(parentDescriptor, path, &destinationStatus, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult == 0 {
            if destinationStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw ScanExportError.symbolicLinkDestination(displayPath)
            }
            throw ScanExportError.destinationExists(displayPath)
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
#endif

    private static func readSnapshotData(from url: URL) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
#if os(Linux)
            return open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
#else
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
#endif
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
#if os(Linux)
            close(descriptor)
#else
            Darwin.close(descriptor)
#endif
        }

        var status = stat()
#if os(Linux)
        let statusResult = fstat(descriptor, &status)
#else
        let statusResult = Darwin.fstat(descriptor, &status)
#endif
        guard statusResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw SnapshotImportError.invalidSnapshot("the snapshot must be a regular file")
        }
        guard status.st_size <= maximumSnapshotBytes else {
            throw SnapshotImportError.resourceLimitExceeded(
                "snapshot files may be at most \(maximumSnapshotBytes) bytes"
            )
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = maximumSnapshotBytes - data.count
            let chunk = try handle.read(upToCount: min(1_024 * 1_024, remaining + 1)) ?? Data()
            guard !chunk.isEmpty else { break }
            guard chunk.count <= remaining else {
                throw SnapshotImportError.resourceLimitExceeded(
                    "snapshot files may be at most \(maximumSnapshotBytes) bytes"
                )
            }
            data.append(chunk)
        }
        try Task.checkCancellation()
        return data
    }

    private static func traverse(
        root: FileNode,
        visit: (_ node: FileNode, _ parentPath: String?) throws -> Void
    ) throws {
        var stack = [TraversalFrame(node: root, parentPath: nil)]
        var entryCount = 0

        while !stack.isEmpty {
            try Task.checkCancellation()
            let frameIndex = stack.count - 1
            if !stack[frameIndex].didVisitNode {
                stack[frameIndex].didVisitNode = true
                entryCount += 1
                guard entryCount <= maximumSnapshotEntries else {
                    throw SnapshotImportError.resourceLimitExceeded(
                        "exports may contain at most \(maximumSnapshotEntries) entries"
                    )
                }
                try visit(stack[frameIndex].node, stack[frameIndex].parentPath)
                continue
            }

            let node = stack[frameIndex].node
            let childIndex = stack[frameIndex].nextChildIndex
            guard childIndex < node.children.count else {
                stack.removeLast()
                continue
            }
            stack[frameIndex].nextChildIndex += 1
            stack.append(TraversalFrame(
                node: node.children[childIndex],
                parentPath: node.path
            ))
        }
    }

    private static func validateSnapshotPathLength(_ path: String) throws {
        guard path.utf8.count <= maximumSnapshotPathBytes else {
            throw SnapshotImportError.resourceLimitExceeded(
                "entry paths may be at most \(maximumSnapshotPathBytes) UTF-8 bytes"
            )
        }
    }

    private struct TraversalFrame {
        let node: FileNode
        let parentPath: String?
        var didVisitNode = false
        var nextChildIndex = 0
    }

    private static func write(_ string: String, to handle: FileHandle) throws {
        guard let data = string.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try handle.write(contentsOf: data)
    }

    private static func writeSnapshot(
        _ string: String,
        to handle: FileHandle,
        bytesWritten: inout Int
    ) throws {
        guard let data = string.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writeSnapshot(data, to: handle, bytesWritten: &bytesWritten)
    }

    private static func writeSnapshot(
        _ data: Data,
        to handle: FileHandle,
        bytesWritten: inout Int
    ) throws {
        guard data.count <= maximumSnapshotBytes - bytesWritten else {
            throw SnapshotImportError.resourceLimitExceeded(
                "snapshot files may be at most \(maximumSnapshotBytes) bytes"
            )
        }
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }

    private static func csvField(_ value: String) -> String {
        let firstSignificantScalar = value.unicodeScalars.first { scalar in
            scalar.value > 0x20 &&
                scalar.value != 0x7F &&
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        let protectsSpreadsheetFormula: Bool
        switch firstSignificantScalar?.value {
        case 0x2B, 0x2D, 0x3D, 0x40,
             0x2212, 0xFF0B, 0xFF0D, 0xFF1D, 0xFF20:
            protectsSpreadsheetFormula = true
        default:
            protectsSpreadsheetFormula = false
        }
        let safeValue = protectsSpreadsheetFormula ? "'" + value : value
        return "\"\(safeValue.replacingOccurrences(of: "\"", with: "\"\""))\""
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
    fileprivate var excludedDirectoryIdentities: Set<String>

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
        close(parentDescriptor)
    }
}
#endif

enum ScanExportError: LocalizedError {
    case symbolicLinkDestination(String)
    case destinationExists(String)
    case invalidDestination(String)
    case invalidTemporaryFile
    case outputInsideScan(String)
    case untrustedDestinationParent(String)

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
        case .untrustedDestinationParent(let path):
            return "Export destination ancestry is writable by an untrusted user: \(path)"
        }
    }
}

enum SnapshotImportError: LocalizedError {
    case unsupportedSchema(Int)
    case missingRoot
    case invalidSnapshot(String)
    case resourceLimitExceeded(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Snapshot schema \(version) is not supported."
        case .missingRoot:
            return "The snapshot does not contain a root entry."
        case .invalidSnapshot(let reason):
            return "The snapshot is invalid: \(reason)."
        case .resourceLimitExceeded(let reason):
            return "The snapshot exceeds a safety limit: \(reason)."
        }
    }
}

struct JSONExportDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let rootPath: String?
    let diagnostics: JSONDiagnostics
    let options: ScanOptions?
    let entries: [JSONExportEntry]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case exportedAt
        case rootPath
        case diagnostics
        case options
        case entries
    }

    init(from decoder: Decoder) throws {
        try Task.checkCancellation()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath)
        if let rootPath,
           rootPath.utf8.count > ScanExporter.maximumSnapshotPathBytes {
            throw SnapshotImportError.resourceLimitExceeded(
                "root paths may be at most \(ScanExporter.maximumSnapshotPathBytes) UTF-8 bytes"
            )
        }
        diagnostics = try container.decode(JSONDiagnostics.self, forKey: .diagnostics)
        options = try container.decodeIfPresent(ScanOptions.self, forKey: .options)

        var entriesContainer = try container.nestedUnkeyedContainer(forKey: .entries)
        if let count = entriesContainer.count,
           count > ScanExporter.maximumSnapshotEntries {
            throw SnapshotImportError.resourceLimitExceeded(
                "snapshots may contain at most \(ScanExporter.maximumSnapshotEntries) entries"
            )
        }
        var decodedEntries: [JSONExportEntry] = []
        decodedEntries.reserveCapacity(min(
            entriesContainer.count ?? 0,
            ScanExporter.maximumSnapshotEntries
        ))
        while !entriesContainer.isAtEnd {
            try Task.checkCancellation()
            guard decodedEntries.count < ScanExporter.maximumSnapshotEntries else {
                throw SnapshotImportError.resourceLimitExceeded(
                    "snapshots may contain at most \(ScanExporter.maximumSnapshotEntries) entries"
                )
            }
            decodedEntries.append(try entriesContainer.decode(JSONExportEntry.self))
        }
        entries = decodedEntries
        try Task.checkCancellation()
    }
}

struct JSONDiagnostics: Codable {
    let unreadableItems: Int
    let skippedDirectories: Int
    let symbolicLinks: Int
    let packages: Int
    let duplicateHardLinks: Int
    let revisitedDirectories: Int
    let firstUnreadablePaths: [String]

    private enum CodingKeys: String, CodingKey {
        case unreadableItems
        case skippedDirectories
        case symbolicLinks
        case packages
        case duplicateHardLinks
        case revisitedDirectories
        case firstUnreadablePaths
    }

    init(_ diagnostics: ScanDiagnostics) {
        unreadableItems = diagnostics.unreadableItems
        skippedDirectories = diagnostics.skippedDirectories
        symbolicLinks = diagnostics.symbolicLinks
        packages = diagnostics.packages
        duplicateHardLinks = diagnostics.duplicateHardLinks
        revisitedDirectories = diagnostics.revisitedDirectories
        firstUnreadablePaths = diagnostics.firstUnreadablePaths
    }

    init(from decoder: Decoder) throws {
        try Task.checkCancellation()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unreadableItems = try container.decodeIfPresent(Int.self, forKey: .unreadableItems) ?? 0
        skippedDirectories = try container.decodeIfPresent(Int.self, forKey: .skippedDirectories) ?? 0
        symbolicLinks = try container.decodeIfPresent(Int.self, forKey: .symbolicLinks) ?? 0
        packages = try container.decodeIfPresent(Int.self, forKey: .packages) ?? 0
        duplicateHardLinks = try container.decodeIfPresent(Int.self, forKey: .duplicateHardLinks) ?? 0
        revisitedDirectories = try container.decodeIfPresent(Int.self, forKey: .revisitedDirectories) ?? 0

        guard container.contains(.firstUnreadablePaths) else {
            firstUnreadablePaths = []
            return
        }
        var pathsContainer = try container.nestedUnkeyedContainer(forKey: .firstUnreadablePaths)
        if let count = pathsContainer.count, count > 20 {
            throw SnapshotImportError.resourceLimitExceeded(
                "snapshots may contain at most 20 unreadable-path examples"
            )
        }
        var paths: [String] = []
        paths.reserveCapacity(min(pathsContainer.count ?? 0, 20))
        while !pathsContainer.isAtEnd {
            try Task.checkCancellation()
            guard paths.count < 20 else {
                throw SnapshotImportError.resourceLimitExceeded(
                    "snapshots may contain at most 20 unreadable-path examples"
                )
            }
            let path = try pathsContainer.decode(String.self)
            guard path.utf8.count <= ScanExporter.maximumSnapshotPathBytes else {
                throw SnapshotImportError.resourceLimitExceeded(
                    "paths may be at most \(ScanExporter.maximumSnapshotPathBytes) UTF-8 bytes"
                )
            }
            paths.append(path)
        }
        firstUnreadablePaths = paths
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

    private enum CodingKeys: String, CodingKey {
        case path
        case parentPath
        case name
        case kind
        case isPackage
        case isSymbolicLink
        case allocatedSize
        case logicalSize
        case childCount
        case totalFileCount
        case totalDirectoryCount
        case creationDate
        case modificationDate
        case isHardLinkDuplicate
        case issue
    }

    init(from decoder: Decoder) throws {
        try Task.checkCancellation()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        parentPath = try container.decodeIfPresent(String.self, forKey: .parentPath)
        name = try container.decode(String.self, forKey: .name)
        for value in [path, parentPath, name].compactMap({ $0 }) {
            guard value.utf8.count <= ScanExporter.maximumSnapshotPathBytes else {
                throw SnapshotImportError.resourceLimitExceeded(
                    "entry paths and names may be at most \(ScanExporter.maximumSnapshotPathBytes) UTF-8 bytes"
                )
            }
        }
        kind = try container.decode(FileNode.Kind.self, forKey: .kind)
        isPackage = try container.decode(Bool.self, forKey: .isPackage)
        isSymbolicLink = try container.decode(Bool.self, forKey: .isSymbolicLink)
        allocatedSize = try container.decode(Int64.self, forKey: .allocatedSize)
        logicalSize = try container.decode(Int64.self, forKey: .logicalSize)
        childCount = try container.decode(Int.self, forKey: .childCount)
        totalFileCount = try container.decodeIfPresent(Int.self, forKey: .totalFileCount)
        totalDirectoryCount = try container.decodeIfPresent(Int.self, forKey: .totalDirectoryCount)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        modificationDate = try container.decodeIfPresent(Date.self, forKey: .modificationDate)
        isHardLinkDuplicate = try container.decode(Bool.self, forKey: .isHardLinkDuplicate)
        issue = try container.decodeIfPresent(String.self, forKey: .issue)
        if let issue,
           issue.utf8.count > ScanExporter.maximumSnapshotIssueBytes {
            throw SnapshotImportError.resourceLimitExceeded(
                "entry issue text may be at most \(ScanExporter.maximumSnapshotIssueBytes) UTF-8 bytes"
            )
        }
        try Task.checkCancellation()
    }

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
