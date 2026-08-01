// Disk Inventory Zed — a modern, fast, native disk usage visualizer
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

@preconcurrency import Foundation

#if os(Linux)
import Glibc
#endif

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
        let rootURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScanError.invalidURL
        }

        let startTime = Date()
        let rootMetadata = try? Self.metadata(
            for: rootURL,
            followSymlinks: true,
            resourceKeys: resourceKeys
        )
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
                canonicalDirectoryPath: Self.canonicalDirectoryPath(for: rootURL)
            )
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
            // Following aliases serially keeps ownership of revisited directory targets stable.
            let workerCount = options.followSymlinks ? 1 : max(2, min(8, processorCount))

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<workerCount {
                    group.addTask { [resourceKeys] in
                        while let work = await queue.next() {
                            do {
                                try Task.checkCancellation()
                                let output = try Self.readDirectory(
                                    work,
                                    options: options,
                                    resourceKeys: resourceKeys
                                )
                                try Task.checkCancellation()
                                await queue.complete(output)
                            } catch is CancellationError {
                                await queue.cancel()
                                throw CancellationError()
                            } catch {
                                await queue.completeFailure(work, error: error)
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            progressTask.cancel()
            await queue.cancel()
            throw error
        }

        progressTask.cancel()
        try Task.checkCancellation()

        let completed = await queue.completedScan()
        guard let root = Self.buildTree(id: rootRecord.id, records: completed.records) else {
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

        return DiskScanResult(
            root: root,
            totalFiles: completed.fileCount,
            totalDirectories: completed.directoryCount,
            duration: Date().timeIntervalSince(startTime),
            diagnostics: completed.diagnostics
        )
    }

    private static func readDirectory(
        _ work: WorkItem,
        options: ScanOptions,
        resourceKeys: Set<URLResourceKey>
    ) throws -> DirectoryOutput {
#if os(Linux)
        let urls = try FileManager().contentsOfDirectory(atPath: work.record.url.path)
            .filter { options.showHiddenFiles || !$0.hasPrefix(".") }
            .map { appendingFileName($0, to: work.record.url) }
#else
        let directoryOptions: FileManager.DirectoryEnumerationOptions =
            options.showHiddenFiles ? [] : [.skipsHiddenFiles]
        let urls = try FileManager().contentsOfDirectory(
            at: work.record.url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: directoryOptions
        )
#endif

        var children: [ChildRecord] = []
        children.reserveCapacity(urls.count)
        var skippedDirectories = 0
        let orderedURLs = options.followSymlinks
            ? urls.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            : urls

        for childURL in orderedURLs {
            try Task.checkCancellation()

            guard let metadata = try? metadata(
                for: childURL,
                followSymlinks: options.followSymlinks,
                resourceKeys: resourceKeys
            ) else {
                let inaccessible = NodeRecord.inaccessible(url: childURL)
                children.append(ChildRecord(record: inaccessible, shouldTraverse: false, canonicalDirectoryPath: nil, fileIdentity: nil))
                continue
            }

            let childIsDirectory = metadata.isDirectory
            let childIsSymlink = metadata.isSymbolicLink
            let childIsPackage = metadata.isPackage
            let lowercasedName = childURL.lastPathComponent.lowercased()

            if options.skipDeveloperFolders,
               childIsDirectory,
               developerFolderNames.contains(lowercasedName) {
                skippedDirectories += 1
                continue
            }

            let shouldFollowDirectory = childIsDirectory && (!childIsSymlink || metadata.followedSymbolicLink)
            let shouldTraverse = shouldFollowDirectory
            let exposesChildren = shouldFollowDirectory && (!childIsPackage || options.showPackageContents)

            let kind: FileNode.Kind
            if childIsSymlink && !metadata.followedSymbolicLink {
                kind = .symbolicLink
            } else if childIsPackage && !options.showPackageContents {
                kind = .package
            } else if shouldFollowDirectory {
                kind = .directory
            } else {
                kind = .file
            }

            let logicalSize = shouldTraverse ? 0 : metadata.logicalSize
            let allocatedSize = shouldTraverse ? 0 : metadata.allocatedSize

            let record = NodeRecord(
                id: fileNodeIdentity(for: childURL),
                url: childURL,
                name: childURL.lastPathComponent,
                kind: kind,
                isPackage: childIsPackage,
                isSymbolicLink: childIsSymlink,
                modificationDate: metadata.modificationDate,
                creationDate: metadata.creationDate,
                extension: childURL.pathExtension.isEmpty ? nil : childURL.pathExtension,
                logicalSize: logicalSize,
                allocatedSize: allocatedSize,
                childIDs: [],
                exposesChildren: exposesChildren,
                errorDescription: metadata.errorDescription,
                isHardLinkDuplicate: false
            )

            let fileIdentity: String?
            if shouldTraverse || kind == .symbolicLink {
                fileIdentity = nil
            } else {
                fileIdentity = metadata.fileIdentity
            }

            children.append(ChildRecord(
                record: record,
                shouldTraverse: shouldTraverse,
                canonicalDirectoryPath: shouldTraverse ? canonicalDirectoryPath(for: childURL) : nil,
                fileIdentity: fileIdentity
            ))
        }

        var parent = work.record
        parent.childIDs = children.map(\.record.id)
        return DirectoryOutput(
            directory: parent,
            children: children,
            skippedDirectories: skippedDirectories
        )
    }

    private static func canonicalDirectoryPath(for url: URL) -> String {
#if os(Linux)
        fileNodeIdentity(for: url.resolvingSymlinksInPath())
#else
        url.resolvingSymlinksInPath().standardizedFileURL.path
#endif
    }

#if os(Linux)
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
#endif

    private static func metadata(
        for url: URL,
        followSymlinks: Bool,
        resourceKeys: Set<URLResourceKey>
    ) throws -> FileSystemMetadata {
#if os(Linux)
        var linkStatus = stat()
        let linkResult = url.path.withCString { path in
            Glibc.lstat(path, &linkStatus)
        }
        guard linkResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let isSymbolicLink = fileType(of: linkStatus.st_mode) == mode_t(S_IFLNK)
        var status = linkStatus
        var followedSymbolicLink = false
        var metadataError: String?
        if isSymbolicLink && followSymlinks {
            var targetStatus = stat()
            let targetResult = url.path.withCString { path in
                stat(path, &targetStatus)
            }
            if targetResult == 0 {
                status = targetStatus
                followedSymbolicLink = true
            } else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                metadataError = "Symbolic link target could not be read: \(error.localizedDescription)"
            }
        }

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
            followedSymbolicLink: followedSymbolicLink,
            logicalSize: logicalSize,
            allocatedSize: overflow ? Int64.max : allocatedBytes,
            modificationDate: modificationDate,
            creationDate: nil,
            fileIdentity: isDirectory || (isSymbolicLink && !followedSymbolicLink)
                ? nil
                : "\(status.st_dev)|\(status.st_ino)",
            errorDescription: metadataError
        )
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
            fileIdentity: identityString(values: values),
            errorDescription: nil
        )
#endif
    }

#if os(Linux)
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

    private static func buildTree(id: String, records: [String: NodeRecord]) -> FileNode? {
        guard records[id] != nil else { return nil }

        var stack: [(id: String, childrenVisited: Bool)] = [(id, false)]
        var builtNodes: [String: FileNode] = [:]
        builtNodes.reserveCapacity(records.count)

        while let item = stack.popLast() {
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

            let aggregateLogicalSize = sortedChildren.reduce(Int64(0)) { $0 + $1.logicalSize }
            let aggregateAllocatedSize = sortedChildren.reduce(Int64(0)) { $0 + $1.allocatedSize }
            let aggregateFileCount = sortedChildren.reduce(0) { $0 + $1.totalFileCount }
            let aggregateDirectoryCount = sortedChildren.reduce(0) { $0 + $1.totalDirectoryCount }
            let isContainer = record.kind == .directory || record.kind == .package

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
                logicalSize: isContainer ? aggregateLogicalSize : record.logicalSize,
                allocatedSize: isContainer ? aggregateAllocatedSize : record.allocatedSize,
                children: record.exposesChildren ? sortedChildren : [],
                errorDescription: record.errorDescription,
                isHardLinkDuplicate: record.isHardLinkDuplicate,
                totalFileCount: isContainer ? aggregateFileCount : 1,
                totalDirectoryCount: isContainer ? 1 + aggregateDirectoryCount : 0
            )
        }

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

private struct FileSystemMetadata {
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let followedSymbolicLink: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let fileIdentity: String?
    let errorDescription: String?
}

// MARK: - Work queue

private struct WorkItem: Sendable {
    let record: NodeRecord
    let canonicalDirectoryPath: String
}

private struct ChildRecord: Sendable {
    var record: NodeRecord
    let shouldTraverse: Bool
    let canonicalDirectoryPath: String?
    let fileIdentity: String?
}

private struct DirectoryOutput: Sendable {
    let directory: NodeRecord
    let children: [ChildRecord]
    let skippedDirectories: Int
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

    static func inaccessible(url: URL) -> NodeRecord {
        NodeRecord(
            id: fileNodeIdentity(for: url),
            url: url,
            name: url.lastPathComponent,
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
            errorDescription: "Metadata could not be read.",
            isHardLinkDuplicate: false
        )
    }
}

private struct CompletedScan: Sendable {
    let records: [String: NodeRecord]
    let fileCount: Int
    let directoryCount: Int
    let diagnostics: ScanDiagnostics
}

private actor ScanWorkQueue {
    private var pending: [WorkItem]
    private var nextIndex = 0
    private var inFlight = 0
    private var waiters: [CheckedContinuation<WorkItem?, Never>] = []
    private var records: [String: NodeRecord]
    private var visitedDirectoryPaths: Set<String>
    private var ownerByFileIdentity: [String: String] = [:]
    private var fileCount = 0
    private var directoryCount = 0
    private var diagnostics = ScanDiagnostics.empty
    private var currentPath: String
    private var isCancelled = false

    init(root: WorkItem) {
        pending = [root]
        records = [root.record.id: root.record]
        visitedDirectoryPaths = [root.canonicalDirectoryPath]
        currentPath = root.record.url.path
    }

    func next() async -> WorkItem? {
        if isCancelled { return nil }
        if nextIndex < pending.count {
            let item = pending[nextIndex]
            nextIndex += 1
            inFlight += 1
            currentPath = item.record.url.path
            return item
        }
        if inFlight == 0 { return nil }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func complete(_ output: DirectoryOutput) {
        guard !isCancelled else {
            finishOneItem()
            return
        }

        records[output.directory.id] = output.directory
        directoryCount += 1
        diagnostics.skippedDirectories += output.skippedDirectories

        for var child in output.children {
            if child.record.errorDescription != nil {
                recordUnreadable(path: child.record.url.path)
            }
            if child.record.isSymbolicLink {
                diagnostics.symbolicLinks += 1
            }
            if child.record.isPackage {
                diagnostics.packages += 1
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
                    diagnostics.revisitedDirectories += 1
                }
            } else {
                if let identity = child.fileIdentity {
                    if let ownerID = ownerByFileIdentity[identity] {
                        diagnostics.duplicateHardLinks += 1
                        if child.record.id < ownerID {
                            if var previousOwner = records[ownerID] {
                                previousOwner.allocatedSize = 0
                                previousOwner.isHardLinkDuplicate = true
                                records[ownerID] = previousOwner
                            }
                            ownerByFileIdentity[identity] = child.record.id
                        } else {
                            child.record.allocatedSize = 0
                            child.record.isHardLinkDuplicate = true
                        }
                    } else {
                        ownerByFileIdentity[identity] = child.record.id
                    }
                }
                records[child.record.id] = child.record
                fileCount += 1
            }
        }

        finishOneItem()
    }

    func completeFailure(_ work: WorkItem, error: Error) {
        var failed = work.record
        failed.childIDs = []
        failed.errorDescription = error.localizedDescription
        records[failed.id] = failed
        directoryCount += 1
        recordUnreadable(path: failed.url.path)
        finishOneItem()
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

    func completedScan() -> CompletedScan {
        CompletedScan(
            records: records,
            fileCount: fileCount,
            directoryCount: directoryCount,
            diagnostics: diagnostics
        )
    }

    private func finishOneItem() {
        inFlight = max(0, inFlight - 1)
        distributeAvailableWork()
    }

    private func distributeAvailableWork() {
        while !waiters.isEmpty && nextIndex < pending.count && !isCancelled {
            let continuation = waiters.removeFirst()
            let item = pending[nextIndex]
            nextIndex += 1
            inFlight += 1
            currentPath = item.record.url.path
            continuation.resume(returning: item)
        }

        if inFlight == 0 && nextIndex >= pending.count {
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume(returning: nil) }
        }
    }

    private func recordUnreadable(path: String) {
        diagnostics.unreadableItems += 1
        if diagnostics.firstUnreadablePaths.count < 20 {
            diagnostics.firstUnreadablePaths.append(path)
        }
    }
}
