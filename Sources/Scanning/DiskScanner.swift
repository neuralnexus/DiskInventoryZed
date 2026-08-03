// Disk Inventory Zed — a modern, fast, native disk usage visualizer
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

@preconcurrency import Foundation

#if os(Linux)
import Glibc
private let linuxOPath = Int32(0o10000000)
#endif

private let maximumScanEntries = 1_000_000
private let maximumDirectoryEntries = 100_000

struct ScanDiagnostics: Sendable, Equatable {
    var unreadableItems = 0
    var skippedDirectories = 0
    var symbolicLinks = 0
    var packages = 0
    var duplicateHardLinks = 0
    var revisitedDirectories = 0
    var firstUnreadablePaths: [String] = []

    static let empty = ScanDiagnostics()
}

struct ScanProgressSnapshot: Sendable {
    let currentPath: String
    let files: Int
    let directories: Int
    let unreadableItems: Int
}

struct DiskScanResult: Sendable {
    let root: FileNode
    let totalFiles: Int
    let totalDirectories: Int
    let duration: TimeInterval
    let diagnostics: ScanDiagnostics
    let scannedDirectoryIdentities: Set<String>
}

struct ScanOptions: Codable, Equatable, Sendable {
    let skipDeveloperFolders: Bool
    let showHiddenFiles: Bool
    let showPackageContents: Bool
    let followSymlinks: Bool

    static let `default` = ScanOptions(
        skipDeveloperFolders: false,
        showHiddenFiles: false,
        showPackageContents: true,
        followSymlinks: false
    )
}

/// A bounded, cancellable scanner that never exposes a tree while it is being mutated.
final class DiskScanner: Sendable {
    enum ScanError: LocalizedError {
        case invalidURL
        case accessDenied(String)
        case directoryChanged(String)
        case directoryEntryLimitExceeded(String, Int)
        case scanEntryLimitExceeded(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The selected location is not a readable folder."
            case .accessDenied(let path):
#if os(macOS)
                return "Disk Inventory Zed could not read \(path). Check Full Disk Access and try again."
#else
                return "Disk Inventory Zed could not read \(path). Check its file permissions and try again."
#endif
            case .directoryChanged(let path):
                return "The directory changed while it was being scanned: \(path)"
            case .directoryEntryLimitExceeded(let path, let limit):
                return "The directory contains more than \(limit) entries and could not be scanned safely: \(path)"
            case .scanEntryLimitExceeded(let limit):
                return "The scan contains more than \(limit) entries and could not be completed safely."
            }
        }
    }

#if os(Linux)
    private let resourceKeys: Set<URLResourceKey> = []
#else
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isHiddenKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileResourceIdentifierKey,
        .volumeIdentifierKey
    ]
#endif

    func scan(
        url: URL,
        options: ScanOptions = .default,
        progressHandler: @escaping @MainActor @Sendable (ScanProgressSnapshot) -> Void
    ) async throws -> DiskScanResult {
        let startTime = Date()
#if os(Linux)
        guard let rootURL = Self.linuxLexicallyStandardizedURL(url) else {
            throw ScanError.invalidURL
        }
        let rootMetadata = try? Self.linuxDirectoryMetadata(for: rootURL)
        guard rootMetadata?.isDirectory == true,
              rootMetadata?.isSymbolicLink == false else {
            throw ScanError.invalidURL
        }
#else
        let rootURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScanError.invalidURL
        }

        let rootMetadata = try? Self.metadata(
            for: rootURL,
            followSymlinks: true,
            resourceKeys: resourceKeys
        )
#endif
        let rootRecord = NodeRecord(
            id: fileNodeIdentity(for: rootURL),
            url: rootURL,
            name: rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent,
            kind: .directory,
            isPackage: false,
            isSymbolicLink: false,
            modificationDate: rootMetadata?.modificationDate,
            creationDate: rootMetadata?.creationDate,
            extension: nil,
            logicalSize: 0,
            allocatedSize: 0,
            childIDs: [],
            exposesChildren: true,
            errorDescription: nil,
            isHardLinkDuplicate: false
        )

        let queue = ScanWorkQueue(
            root: WorkItem(
                record: rootRecord,
                canonicalDirectoryPath: Self.canonicalDirectoryPath(
                    for: rootURL,
                    metadata: rootMetadata
                )
            ),
            rootDirectoryIdentity: rootMetadata?.directoryIdentity
        )

        let progressTask = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 125_000_000)
                    let snapshot = await queue.progressSnapshot()
                    await progressHandler(snapshot)
                }
            } catch {
                // Cancellation is the normal way this reporter is stopped.
            }
        }

        do {
            let processorCount = ProcessInfo.processInfo.activeProcessorCount
#if os(Linux)
            let workerCount = max(2, min(8, processorCount))
#else
            // Following aliases serially keeps ownership of revisited directory targets stable.
            let workerCount = options.followSymlinks ? 1 : max(2, min(8, processorCount))
#endif

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<workerCount {
                    group.addTask { [resourceKeys] in
                        do {
                            while let work = await queue.next() {
                                var examinedEntryCount = 0
                                do {
                                    try Task.checkCancellation()
                                    let output = try Self.readDirectory(
                                        work,
                                        options: options,
                                        resourceKeys: resourceKeys,
                                        examinedEntryCount: &examinedEntryCount
                                    )
                                    try Task.checkCancellation()
                                    try await queue.complete(
                                        output,
                                        examinedEntryCount: examinedEntryCount
                                    )
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch let error as ScanError {
                                    if work.record.id == rootRecord.id {
                                        throw error
                                    }
                                    if case .scanEntryLimitExceeded = error {
                                        throw error
                                    }
                                    try await queue.completeFailure(
                                        work,
                                        error: error,
                                        examinedEntryCount: examinedEntryCount
                                    )
                                } catch {
                                    try await queue.completeFailure(
                                        work,
                                        error: error,
                                        examinedEntryCount: examinedEntryCount
                                    )
                                }
                            }
                        } catch {
                            await queue.cancel()
                            throw error
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            progressTask.cancel()
            await progressTask.value
            await queue.cancel()
            throw error
        }

        progressTask.cancel()
        await progressTask.value
        try Task.checkCancellation()

        let completed = try await queue.completedScan()
        guard let root = try Self.buildTree(id: rootRecord.id, records: completed.records) else {
            throw ScanError.invalidURL
        }
        if root.isUnreadable && root.children.isEmpty {
            throw ScanError.accessDenied(root.path)
        }

        let finalProgress = ScanProgressSnapshot(
            currentPath: root.path,
            files: completed.fileCount,
            directories: completed.directoryCount,
            unreadableItems: completed.diagnostics.unreadableItems
        )
        await progressHandler(finalProgress)

        try Task.checkCancellation()
        return DiskScanResult(
            root: root,
            totalFiles: completed.fileCount,
            totalDirectories: completed.directoryCount,
            duration: Date().timeIntervalSince(startTime),
            diagnostics: completed.diagnostics,
            scannedDirectoryIdentities: completed.directoryIdentities
        )
    }

    private static func readDirectory(
        _ work: WorkItem,
        options: ScanOptions,
        resourceKeys: Set<URLResourceKey>,
        examinedEntryCount: inout Int
    ) throws -> DirectoryOutput {
#if os(Linux)
        let listing = try linuxDirectoryEntries(
            for: work,
            options: options,
            examinedEntryCount: &examinedEntryCount
        )
        let entries = listing.entries
#else
        let directoryOptions: FileManager.DirectoryEnumerationOptions = [
            .skipsSubdirectoryDescendants
        ]
        var enumerationError: Error?
        guard let enumerator = FileManager().enumerator(
            at: work.record.url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: directoryOptions,
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var entries: [ScannedDirectoryEntry] = []
        while let value = enumerator.nextObject() {
            try Task.checkCancellation()
            guard let url = value as? URL else { continue }
            guard examinedEntryCount < maximumDirectoryEntries else {
                throw ScanError.directoryEntryLimitExceeded(
                    work.record.url.path,
                    maximumDirectoryEntries
                )
            }
            examinedEntryCount += 1
            if !options.showHiddenFiles {
                let isHidden = (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
                if isHidden || url.lastPathComponent.hasPrefix(".") {
                    continue
                }
            }
            entries.append(ScannedDirectoryEntry(
                url: url,
                metadata: nil
            ))
        }
        if let enumerationError {
            throw enumerationError
        }
#endif

        var children: [ChildRecord] = []
        children.reserveCapacity(entries.count)
        var skippedDirectories = 0
#if os(Linux)
        var observedDirectoryIdentities = listing.observedDirectoryIdentities
#else
        var observedDirectoryIdentities: Set<String> = []
#endif
        let orderedURLs = options.followSymlinks
            ? entries.sorted { $0.url.path.utf8.lexicographicallyPrecedes($1.url.path.utf8) }
            : entries

        for entry in orderedURLs {
            try Task.checkCancellation()
            let childURL = entry.url
            let childID = entry.id ?? fileNodeIdentity(for: childURL)
            let childName = entry.name ?? childURL.lastPathComponent

#if os(Linux)
            let childMetadata = entry.metadata
#else
            let childMetadata = try? metadata(
                for: childURL,
                followSymlinks: options.followSymlinks,
                resourceKeys: resourceKeys
            )
#endif
            guard let metadata = childMetadata else {
                let inaccessible = NodeRecord.inaccessible(
                    url: childURL,
                    id: childID,
                    name: childName,
                    errorDescription: entry.errorDescription
                )
                children.append(ChildRecord(record: inaccessible, shouldTraverse: false, canonicalDirectoryPath: nil, fileIdentity: nil))
                continue
            }

            if let directoryIdentity = metadata.directoryIdentity {
                observedDirectoryIdentities.insert(directoryIdentity)
            }

            let childIsDirectory = metadata.isDirectory
            let childIsSymlink = metadata.isSymbolicLink
            let childIsPackage = metadata.isPackage
            let lowercasedName = childName.lowercased()

            if options.skipDeveloperFolders,
               childIsDirectory,
               developerFolderNames.contains(lowercasedName) {
                skippedDirectories = saturatingAdd(skippedDirectories, 1)
                continue
            }

            let isTraversableDirectory = childIsDirectory && (!childIsSymlink || metadata.followedSymbolicLink)
            let shouldTraverse = isTraversableDirectory && entry.errorDescription == nil
            let exposesChildren = shouldTraverse && (!childIsPackage || options.showPackageContents)

            let kind: FileNode.Kind
            if childIsSymlink && !metadata.followedSymbolicLink {
                kind = .symbolicLink
            } else if childIsPackage && !options.showPackageContents {
                kind = .package
            } else if childIsDirectory {
                kind = .directory
            } else {
                kind = .file
            }

            let omitsDirectoryMetadataSize = childIsDirectory && entry.errorDescription != nil
            let logicalSize = shouldTraverse || omitsDirectoryMetadataSize ? 0 : metadata.logicalSize
            let allocatedSize = shouldTraverse || omitsDirectoryMetadataSize ? 0 : metadata.allocatedSize

            let record = NodeRecord(
                id: childID,
                url: childURL,
                name: childName,
                kind: kind,
                isPackage: childIsPackage,
                isSymbolicLink: childIsSymlink,
                modificationDate: metadata.modificationDate,
                creationDate: metadata.creationDate,
                extension: entry.errorDescription == nil && !childURL.pathExtension.isEmpty
                    ? childURL.pathExtension
                    : nil,
                logicalSize: logicalSize,
                allocatedSize: allocatedSize,
                childIDs: [],
                exposesChildren: exposesChildren,
                errorDescription: entry.errorDescription ?? metadata.errorDescription,
                isHardLinkDuplicate: false
            )

            let fileIdentity: FileIdentity?
#if os(Linux)
            if shouldTraverse {
                fileIdentity = nil
            } else {
                fileIdentity = metadata.fileIdentity
            }
#else
            if shouldTraverse || kind == .symbolicLink {
                fileIdentity = nil
            } else {
                fileIdentity = metadata.fileIdentity
            }
#endif

            children.append(ChildRecord(
                record: record,
                shouldTraverse: shouldTraverse,
                canonicalDirectoryPath: shouldTraverse
                    ? canonicalDirectoryPath(for: childURL, metadata: metadata)
                    : nil,
                fileIdentity: fileIdentity
            ))
        }

        var parent = work.record
        parent.childIDs = children.map(\.record.id)
        return DirectoryOutput(
            directory: parent,
            children: children,
            skippedDirectories: skippedDirectories,
            observedDirectoryIdentities: observedDirectoryIdentities
        )
    }

    private static func canonicalDirectoryPath(
        for url: URL,
        metadata: FileSystemMetadata?
    ) -> String {
#if os(Linux)
        if let identity = metadata?.directoryIdentity,
           let generation = metadata?.directoryGeneration {
            return "\(identity)|\(generation)"
        }
        return fileNodeIdentity(for: url)
#else
        url.resolvingSymlinksInPath().standardizedFileURL.path
#endif
    }

#if os(Linux)
    // Bounds transient URL/metadata materialization while still accommodating unusually large directories.
    private static func linuxDirectoryEntries(
        for work: WorkItem,
        options: ScanOptions,
        examinedEntryCount: inout Int
    ) throws -> LinuxDirectoryListing {
        let descriptor = try openDirectoryWithoutFollowingSymlinks(at: work.record.url)
        guard let directory = Glibc.fdopendir(descriptor) else {
            let errorCode = errno
            Glibc.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }
        defer { Glibc.closedir(directory) }

        let directoryDescriptor = Glibc.dirfd(directory)
        var openedStatus = stat()
        guard Glibc.fstat(directoryDescriptor, &openedStatus) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fileType(of: openedStatus.st_mode) == mode_t(S_IFDIR),
              linuxCanonicalDirectoryIdentity(openedStatus) == work.canonicalDirectoryPath else {
            throw ScanError.directoryChanged(work.record.url.path)
        }

        var entries: [ScannedDirectoryEntry] = []
        var opaqueEntries: [(nameBytes: [UInt8], metadata: FileSystemMetadata?)] = []
        var representedNames: Set<String> = []
        var observedDirectoryIdentities: Set<String> = []

        while true {
            try Task.checkCancellation()
            errno = 0
            guard let directoryEntry = Glibc.readdir(directory) else {
                guard errno == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                break
            }

            var nameStorage = directoryEntry.pointee.d_name
            let nameBytes = withUnsafeBytes(of: &nameStorage) { storage in
                Array(storage.prefix { $0 != 0 })
            }
            if nameBytes == [UInt8(ascii: ".")] ||
                nameBytes == [UInt8(ascii: "."), UInt8(ascii: ".")] {
                continue
            }
            guard examinedEntryCount < maximumDirectoryEntries else {
                throw ScanError.directoryEntryLimitExceeded(
                    work.record.url.path,
                    maximumDirectoryEntries
                )
            }
            examinedEntryCount += 1
            if !options.showHiddenFiles, nameBytes.first == UInt8(ascii: ".") {
                continue
            }

            var childStatus = stat()
            var fileSystemName = nameBytes.map { CChar(bitPattern: $0) }
            fileSystemName.append(0)
            let statusResult = fileSystemName.withUnsafeBufferPointer { buffer in
                Glibc.fstatat(
                    directoryDescriptor,
                    buffer.baseAddress!,
                    &childStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            let childMetadata = statusResult == 0 ? linuxMetadata(from: childStatus) : nil
            if let directoryIdentity = childMetadata?.directoryIdentity {
                observedDirectoryIdentities.insert(directoryIdentity)
            }

            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                opaqueEntries.append((nameBytes: nameBytes, metadata: childMetadata))
                continue
            }

            representedNames.insert(name)
            let childURL = appendingFileName(name, to: work.record.url)
            entries.append(ScannedDirectoryEntry(
                url: childURL,
                metadata: childMetadata
            ))
        }

        for opaqueEntry in opaqueEntries {
            let encodedName = linuxOpaqueName(
                for: opaqueEntry.nameBytes,
                avoiding: &representedNames
            )
            let childURL = appendingFileName(encodedName, to: work.record.url)
            entries.append(ScannedDirectoryEntry(
                url: childURL,
                metadata: opaqueEntry.metadata,
                id: linuxChildIdentity(nameBytes: opaqueEntry.nameBytes, in: work.record.url),
                name: encodedName,
                errorDescription: "The file name is not valid UTF-8, so this entry could not be traversed or exported."
            ))
        }

        var verificationStatus = stat()
        guard Glibc.fstat(directoryDescriptor, &verificationStatus) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard linuxCanonicalDirectoryIdentity(verificationStatus) == work.canonicalDirectoryPath,
              openedStatus.st_ctim.tv_sec == verificationStatus.st_ctim.tv_sec,
              openedStatus.st_ctim.tv_nsec == verificationStatus.st_ctim.tv_nsec,
              openedStatus.st_mtim.tv_sec == verificationStatus.st_mtim.tv_sec,
              openedStatus.st_mtim.tv_nsec == verificationStatus.st_mtim.tv_nsec else {
            throw ScanError.directoryChanged(work.record.url.path)
        }

        let pathDescriptor = try openDirectoryWithoutFollowingSymlinks(at: work.record.url)
        defer { Glibc.close(pathDescriptor) }
        var pathStatus = stat()
        guard Glibc.fstat(pathDescriptor, &pathStatus) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard linuxCanonicalDirectoryIdentity(pathStatus) == work.canonicalDirectoryPath else {
            throw ScanError.directoryChanged(work.record.url.path)
        }

        return LinuxDirectoryListing(
            entries: entries,
            observedDirectoryIdentities: observedDirectoryIdentities
        )
    }

    private static func linuxDirectoryMetadata(for url: URL) throws -> FileSystemMetadata {
        let descriptor = try openDirectoryWithoutFollowingSymlinks(at: url)
        defer { Glibc.close(descriptor) }
        var status = stat()
        guard Glibc.fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return linuxMetadata(from: status)
    }

    private static func linuxLexicallyStandardizedURL(_ url: URL) -> URL? {
        var components: [Substring] = []
        for component in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return nil }
            components.append(component)
        }
        let path = "/" + components.joined(separator: "/")
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func openDirectoryWithoutFollowingSymlinks(at url: URL) throws -> Int32 {
        let components = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        let rootFlags = components.isEmpty
            ? O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            : linuxOPath | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = Glibc.open("/", rootFlags)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        for (index, component) in components.enumerated() {
            let isFinalComponent = index == components.count - 1
            let flags = isFinalComponent
                ? O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                : linuxOPath | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let nextDescriptor = component.withCString { name in
                Glibc.openat(descriptor, name, flags)
            }
            guard nextDescriptor >= 0 else {
                let errorCode = errno
                Glibc.close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
            }
            Glibc.close(descriptor)
            descriptor = nextDescriptor
        }

        return descriptor
    }

    private static func appendingFileName(_ name: String, to directoryURL: URL) -> URL {
        directoryURL.withUnsafeFileSystemRepresentation { directoryPath in
            guard let directoryPath else {
                return directoryURL.appendingPathComponent(name)
            }

            var path: [CChar] = []
            var index = 0
            while directoryPath[index] != 0 {
                path.append(directoryPath[index])
                index += 1
            }
            if path.last != CChar(47) {
                path.append(CChar(47))
            }
            path.append(contentsOf: name.utf8.map { CChar(bitPattern: $0) })
            path.append(0)

            return path.withUnsafeBufferPointer { buffer in
                URL(
                    fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                    isDirectory: false,
                    relativeTo: nil
                )
            }
        }
    }

    private static func linuxOpaqueName(
        for nameBytes: [UInt8],
        avoiding representedNames: inout Set<String>
    ) -> String {
        let encoded = Data(nameBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let baseName = "<non-UTF-8:\(encoded)>"
        var candidate = baseName
        var suffix = 2
        while !representedNames.insert(candidate).inserted {
            candidate = "<non-UTF-8:\(encoded):\(suffix)>"
            suffix += 1
        }
        return candidate
    }

    private static func linuxChildIdentity(nameBytes: [UInt8], in directoryURL: URL) -> String {
        directoryURL.withUnsafeFileSystemRepresentation { directoryPath in
            guard let directoryPath else {
                return "\(fileNodeIdentity(for: directoryURL))|\(Data(nameBytes).base64EncodedString())"
            }

            var pathBytes: [UInt8] = []
            var index = 0
            while directoryPath[index] != 0 {
                pathBytes.append(UInt8(bitPattern: directoryPath[index]))
                index += 1
            }
            if pathBytes.last != UInt8(ascii: "/") {
                pathBytes.append(UInt8(ascii: "/"))
            }
            pathBytes.append(contentsOf: nameBytes)
            return Data(pathBytes).base64EncodedString()
        }
    }
#endif

    private static func metadata(
        for url: URL,
        followSymlinks: Bool,
        resourceKeys: Set<URLResourceKey>
    ) throws -> FileSystemMetadata {
#if os(Linux)
        _ = followSymlinks
        _ = resourceKeys
        var linkStatus = stat()
        let linkResult = url.path.withCString { path in
            Glibc.lstat(path, &linkStatus)
        }
        guard linkResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return linuxMetadata(from: linkStatus)
#else
        let values = try url.resourceValues(forKeys: resourceKeys)
        let logicalSize = Int64(values.fileSize ?? 0)
        return FileSystemMetadata(
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false,
            isSymbolicLink: values.isSymbolicLink ?? false,
            followedSymbolicLink: (values.isSymbolicLink ?? false) && followSymlinks,
            logicalSize: logicalSize,
            allocatedSize: Int64(
                values.totalFileAllocatedSize ??
                values.fileAllocatedSize ??
                values.fileSize ??
                0
            ),
            modificationDate: values.contentModificationDate,
            creationDate: values.creationDate,
            fileIdentity: identityString(values: values).map {
                FileIdentity(key: $0, generation: nil)
            },
            directoryIdentity: values.isDirectory == true
                ? identityString(values: values)
                : nil,
            directoryGeneration: nil,
            errorDescription: nil
        )
#endif
    }

#if os(Linux)
    private static func linuxMetadata(from status: stat) -> FileSystemMetadata {
        let isSymbolicLink = fileType(of: status.st_mode) == mode_t(S_IFLNK)
        let isDirectory = fileType(of: status.st_mode) == mode_t(S_IFDIR)
        let logicalSize = max(0, Int64(status.st_size))
        let blocks = max(0, Int64(status.st_blocks))
        let (allocatedBytes, overflow) = blocks.multipliedReportingOverflow(by: 512)
        let modificationDate = Date(
            timeIntervalSince1970: TimeInterval(status.st_mtim.tv_sec) +
                TimeInterval(status.st_mtim.tv_nsec) / 1_000_000_000
        )

        return FileSystemMetadata(
            isDirectory: isDirectory,
            isPackage: false,
            isSymbolicLink: isSymbolicLink,
            followedSymbolicLink: false,
            logicalSize: logicalSize,
            allocatedSize: overflow ? Int64.max : allocatedBytes,
            modificationDate: modificationDate,
            creationDate: nil,
            fileIdentity: !isDirectory
                ? linuxHardLinkIdentity(status)
                : nil,
            directoryIdentity: isDirectory ? linuxDirectoryIdentity(status) : nil,
            directoryGeneration: isDirectory ? linuxDirectoryGeneration(status) : nil,
            errorDescription: nil
        )
    }

    private static func linuxDirectoryIdentity(_ status: stat) -> String {
        "\(status.st_dev)|\(status.st_ino)"
    }

    private static func linuxDirectoryGeneration(_ status: stat) -> String {
        "\(status.st_ctim.tv_sec)|\(status.st_ctim.tv_nsec)"
    }

    private static func linuxCanonicalDirectoryIdentity(_ status: stat) -> String {
        "\(linuxDirectoryIdentity(status))|\(linuxDirectoryGeneration(status))"
    }

    private static func linuxHardLinkIdentity(_ status: stat) -> FileIdentity {
        FileIdentity(
            key: "\(status.st_dev)|\(status.st_ino)",
            generation: "\(status.st_ctim.tv_sec)|\(status.st_ctim.tv_nsec)"
        )
    }

    private static func fileType(of mode: mode_t) -> mode_t {
        mode & mode_t(S_IFMT)
    }
#endif

#if !os(Linux)
    private static func identityString(values: URLResourceValues) -> String? {
        guard let fileID = values.fileResourceIdentifier else { return nil }
        let volumeID = values.volumeIdentifier.map { String(describing: $0) } ?? "unknown-volume"
        return "\(volumeID)|\(String(describing: fileID))"
    }
#endif

    private static func buildTree(id: String, records: [String: NodeRecord]) throws -> FileNode? {
        try Task.checkCancellation()
        guard records[id] != nil else { return nil }

        var stack: [(id: String, childrenVisited: Bool)] = [(id, false)]
        var builtNodes: [String: FileNode] = [:]
        builtNodes.reserveCapacity(records.count)

        while let item = stack.popLast() {
            try Task.checkCancellation()
            guard let record = records[item.id] else { continue }

            if !item.childrenVisited {
                stack.append((item.id, true))
                for childID in record.childIDs.reversed() where builtNodes[childID] == nil {
                    stack.append((childID, false))
                }
                continue
            }

            let sortedChildren = record.childIDs.compactMap { builtNodes[$0] }.sorted {
                if $0.allocatedSize == $1.allocatedSize {
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                return $0.allocatedSize > $1.allocatedSize
            }
            try Task.checkCancellation()

            var aggregateLogicalSize: Int64 = 0
            var aggregateAllocatedSize: Int64 = 0
            var aggregateFileCount = 0
            var aggregateDirectoryCount = 0
            for child in sortedChildren {
                try Task.checkCancellation()
                aggregateLogicalSize = saturatingAdd(aggregateLogicalSize, child.logicalSize)
                aggregateAllocatedSize = saturatingAdd(aggregateAllocatedSize, child.allocatedSize)
                aggregateFileCount = saturatingAdd(aggregateFileCount, child.totalFileCount)
                aggregateDirectoryCount = saturatingAdd(
                    aggregateDirectoryCount,
                    child.totalDirectoryCount
                )
            }
            let isContainer = record.kind == .directory || record.kind == .package
            let aggregatesChildSizes = isContainer && (record.exposesChildren || !record.childIDs.isEmpty)

            builtNodes[item.id] = FileNode(
                id: record.id,
                url: record.url,
                name: record.name,
                kind: record.kind,
                isPackage: record.isPackage,
                isSymbolicLink: record.isSymbolicLink,
                modificationDate: record.modificationDate,
                creationDate: record.creationDate,
                extension: record.extension,
                logicalSize: aggregatesChildSizes ? aggregateLogicalSize : record.logicalSize,
                allocatedSize: aggregatesChildSizes ? aggregateAllocatedSize : record.allocatedSize,
                children: record.exposesChildren ? sortedChildren : [],
                errorDescription: record.errorDescription,
                isHardLinkDuplicate: record.isHardLinkDuplicate,
                totalFileCount: isContainer ? aggregateFileCount : 1,
                totalDirectoryCount: isContainer
                    ? saturatingAdd(1, aggregateDirectoryCount)
                    : 0
            )
        }

        try Task.checkCancellation()
        return builtNodes[id]
    }

    private static let developerFolderNames: Set<String> = [
        "node_modules",
        ".git",
        ".svn",
        ".hg",
        "deriveddata",
        ".build"
    ]
}

private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? (rhs >= 0 ? .max : .min) : result
}

private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? (rhs >= 0 ? .max : .min) : result
}

private struct FileIdentity: Sendable {
    let key: String
    let generation: String?
}

private struct FileSystemMetadata {
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let followedSymbolicLink: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let fileIdentity: FileIdentity?
    let directoryIdentity: String?
    let directoryGeneration: String?
    let errorDescription: String?
}

// MARK: - Work queue

private struct ScannedDirectoryEntry {
    let url: URL
    let metadata: FileSystemMetadata?
    let id: String?
    let name: String?
    let errorDescription: String?

    init(
        url: URL,
        metadata: FileSystemMetadata?,
        id: String? = nil,
        name: String? = nil,
        errorDescription: String? = nil
    ) {
        self.url = url
        self.metadata = metadata
        self.id = id
        self.name = name
        self.errorDescription = errorDescription
    }
}

#if os(Linux)
private struct LinuxDirectoryListing {
    let entries: [ScannedDirectoryEntry]
    let observedDirectoryIdentities: Set<String>
}
#endif

private struct WorkItem: Sendable {
    let record: NodeRecord
    let canonicalDirectoryPath: String
}

private struct ChildRecord: Sendable {
    var record: NodeRecord
    let shouldTraverse: Bool
    let canonicalDirectoryPath: String?
    let fileIdentity: FileIdentity?
}

private struct DirectoryOutput: Sendable {
    let directory: NodeRecord
    let children: [ChildRecord]
    let skippedDirectories: Int
    let observedDirectoryIdentities: Set<String>
}

private struct NodeRecord: Sendable {
    let id: String
    let url: URL
    let name: String
    var kind: FileNode.Kind
    let isPackage: Bool
    let isSymbolicLink: Bool
    let modificationDate: Date?
    let creationDate: Date?
    let `extension`: String?
    var logicalSize: Int64
    var allocatedSize: Int64
    var childIDs: [String]
    let exposesChildren: Bool
    var errorDescription: String?
    var isHardLinkDuplicate: Bool

    static func inaccessible(
        url: URL,
        id: String? = nil,
        name: String? = nil,
        errorDescription: String? = nil
    ) -> NodeRecord {
        NodeRecord(
            id: id ?? fileNodeIdentity(for: url),
            url: url,
            name: name ?? url.lastPathComponent,
            kind: .file,
            isPackage: false,
            isSymbolicLink: false,
            modificationDate: nil,
            creationDate: nil,
            extension: url.pathExtension.isEmpty ? nil : url.pathExtension,
            logicalSize: 0,
            allocatedSize: 0,
            childIDs: [],
            exposesChildren: false,
            errorDescription: errorDescription ?? "Metadata could not be read.",
            isHardLinkDuplicate: false
        )
    }
}

private struct CompletedScan: Sendable {
    let records: [String: NodeRecord]
    let fileCount: Int
    let directoryCount: Int
    let diagnostics: ScanDiagnostics
    let directoryIdentities: Set<String>
}

private actor ScanWorkQueue {
    private var pending: [WorkItem]
    private var nextIndex = 0
    private var inFlight = 0
    private var waiters: [CheckedContinuation<WorkItem?, Never>] = []
    private var records: [String: NodeRecord]
    private var visitedDirectoryPaths: Set<String>
    private var knownDirectoryIdentities: Set<String>
    private var ownerByFileIdentity: [String: (id: String, generation: String?)] = [:]
    private var examinedEntryCount = 1
    private var fileCount = 0
    private var directoryCount = 0
    private var diagnostics = ScanDiagnostics.empty
    private var currentPath: String
    private var isCancelled = false

    init(root: WorkItem, rootDirectoryIdentity: String?) {
        pending = [root]
        records = [root.record.id: root.record]
        visitedDirectoryPaths = [root.canonicalDirectoryPath]
        knownDirectoryIdentities = rootDirectoryIdentity.map { Set([$0]) } ?? []
        currentPath = root.record.url.path
    }

    func next() async -> WorkItem? {
        if isCancelled { return nil }
        if let item = takeNextPendingItem() {
            inFlight = saturatingAdd(inFlight, 1)
            currentPath = item.record.url.path
            return item
        }
        if inFlight == 0 { return nil }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func complete(_ output: DirectoryOutput, examinedEntryCount newEntryCount: Int) throws {
        try Task.checkCancellation()
        guard !isCancelled else {
            finishOneItem()
            return
        }
        guard newEntryCount <= maximumScanEntries - examinedEntryCount else {
            throw DiskScanner.ScanError.scanEntryLimitExceeded(maximumScanEntries)
        }
        examinedEntryCount += newEntryCount

        records[output.directory.id] = output.directory
        directoryCount = saturatingAdd(directoryCount, 1)
        diagnostics.skippedDirectories = saturatingAdd(
            diagnostics.skippedDirectories,
            output.skippedDirectories
        )
        knownDirectoryIdentities.formUnion(output.observedDirectoryIdentities)

        for var child in output.children {
            try Task.checkCancellation()
            if child.record.errorDescription != nil {
                recordUnreadable(path: child.record.url.path)
            }
            if child.record.isSymbolicLink {
                diagnostics.symbolicLinks = saturatingAdd(diagnostics.symbolicLinks, 1)
            }
            if child.record.isPackage {
                diagnostics.packages = saturatingAdd(diagnostics.packages, 1)
            }

            if child.shouldTraverse,
               let canonicalPath = child.canonicalDirectoryPath {
                if visitedDirectoryPaths.insert(canonicalPath).inserted {
                    records[child.record.id] = child.record
                    pending.append(WorkItem(record: child.record, canonicalDirectoryPath: canonicalPath))
                } else {
                    child.record.childIDs = []
                    child.record.logicalSize = 0
                    child.record.allocatedSize = 0
                    child.record.errorDescription = "Directory target was already scanned; it was not followed again."
                    records[child.record.id] = child.record
                    directoryCount = saturatingAdd(directoryCount, 1)
                    diagnostics.revisitedDirectories = saturatingAdd(
                        diagnostics.revisitedDirectories,
                        1
                    )
                }
            } else {
                if let identity = child.fileIdentity {
                    if let owner = ownerByFileIdentity[identity.key],
                       owner.generation == identity.generation {
                        diagnostics.duplicateHardLinks = saturatingAdd(
                            diagnostics.duplicateHardLinks,
                            1
                        )
                        if child.record.id < owner.id {
                            if var previousOwner = records[owner.id] {
                                previousOwner.allocatedSize = 0
                                previousOwner.isHardLinkDuplicate = true
                                records[owner.id] = previousOwner
                            }
                            ownerByFileIdentity[identity.key] = (
                                id: child.record.id,
                                generation: identity.generation
                            )
                        } else {
                            child.record.allocatedSize = 0
                            child.record.isHardLinkDuplicate = true
                        }
                    } else if ownerByFileIdentity[identity.key] != nil {
                        if child.record.errorDescription == nil {
                            child.record.errorDescription = "The file identity changed while it was being scanned; its storage may be counted more than once."
                            recordUnreadable(path: child.record.url.path)
                        }
                        ownerByFileIdentity[identity.key] = (
                            id: child.record.id,
                            generation: identity.generation
                        )
                    } else {
                        ownerByFileIdentity[identity.key] = (
                            id: child.record.id,
                            generation: identity.generation
                        )
                    }
                }
                records[child.record.id] = child.record
                if child.record.kind == .directory || child.record.kind == .package {
                    directoryCount = saturatingAdd(directoryCount, 1)
                } else {
                    fileCount = saturatingAdd(fileCount, 1)
                }
            }
        }

        try Task.checkCancellation()
        finishOneItem()
        try Task.checkCancellation()
    }

    func completeFailure(
        _ work: WorkItem,
        error: Error,
        examinedEntryCount newEntryCount: Int
    ) throws {
        try Task.checkCancellation()
        guard !isCancelled else {
            finishOneItem()
            return
        }
        guard newEntryCount <= maximumScanEntries - examinedEntryCount else {
            throw DiskScanner.ScanError.scanEntryLimitExceeded(maximumScanEntries)
        }
        examinedEntryCount += newEntryCount
        var failed = work.record
        failed.childIDs = []
        failed.errorDescription = error.localizedDescription
        records[failed.id] = failed
        directoryCount = saturatingAdd(directoryCount, 1)
        recordUnreadable(path: failed.url.path)
        try Task.checkCancellation()
        finishOneItem()
        try Task.checkCancellation()
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        pending.removeAll(keepingCapacity: false)
        nextIndex = 0
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume(returning: nil) }
    }

    func progressSnapshot() -> ScanProgressSnapshot {
        ScanProgressSnapshot(
            currentPath: currentPath,
            files: fileCount,
            directories: directoryCount,
            unreadableItems: diagnostics.unreadableItems
        )
    }

    func completedScan() throws -> CompletedScan {
        try Task.checkCancellation()
        let completed = CompletedScan(
            records: records,
            fileCount: fileCount,
            directoryCount: directoryCount,
            diagnostics: diagnostics,
            directoryIdentities: knownDirectoryIdentities
        )
        try Task.checkCancellation()
        return completed
    }

    private func finishOneItem() {
        inFlight = max(0, inFlight - 1)
        distributeAvailableWork()
    }

    private func distributeAvailableWork() {
        while !waiters.isEmpty && !isCancelled,
              let item = takeNextPendingItem() {
            let continuation = waiters.removeFirst()
            inFlight = saturatingAdd(inFlight, 1)
            currentPath = item.record.url.path
            continuation.resume(returning: item)
        }

        if inFlight == 0 && pending.isEmpty {
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume(returning: nil) }
        }
    }

    private func takeNextPendingItem() -> WorkItem? {
        guard nextIndex < pending.count else { return nil }
        let item = pending[nextIndex]
        nextIndex += 1

        if nextIndex == pending.count {
            pending.removeAll(keepingCapacity: false)
            nextIndex = 0
        } else if nextIndex >= 1_024,
                  nextIndex >= pending.count - nextIndex {
            pending.removeFirst(nextIndex)
            nextIndex = 0
        }
        return item
    }

    private func recordUnreadable(path: String) {
        diagnostics.unreadableItems = saturatingAdd(diagnostics.unreadableItems, 1)
        if diagnostics.firstUnreadablePaths.count < 20 {
            diagnostics.firstUnreadablePaths.append(path)
        }
    }
}
