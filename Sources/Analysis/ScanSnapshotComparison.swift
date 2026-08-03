// Disk Inventory Zed — scan snapshot comparison
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

import Foundation

struct ImportedScanSnapshot: Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let rootPath: String
    let entries: [JSONExportEntry]
    let diagnostics: ScanDiagnostics
    let options: ScanOptions?
    let isValidated: Bool

    init(
        schemaVersion: Int,
        exportedAt: Date,
        rootPath: String,
        entries: [JSONExportEntry],
        diagnostics: ScanDiagnostics,
        options: ScanOptions? = nil,
        isValidated: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.rootPath = rootPath
        self.entries = entries
        self.diagnostics = diagnostics
        self.options = options
        self.isValidated = isValidated
    }
}

struct ScanChange: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case added
        case removed
        case grew
        case shrank
    }

    let path: String
    let kind: Kind
    let previousSize: Int64
    let currentSize: Int64
    let currentNode: FileNode?

    var id: String { "\(kind.rawValue)|\(path)" }
    var delta: Int64 { saturatingDifference(currentSize, previousSize) }
    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

struct ScanComparison: Sendable {
    let baselineDate: Date
    let rootPath: String
    let totalDelta: Int64
    let addedCount: Int
    let removedCount: Int
    let changedCount: Int
    let largestGrowth: [ScanChange]
    let largestShrinkage: [ScanChange]
    let baselineDiagnostics: ScanDiagnostics
    let reliabilityWarning: String?
}

enum ScanSnapshotValidator {
    static func validate(
        entries: [JSONExportEntry],
        declaredRootPath: String?,
        diagnostics: ScanDiagnostics
    ) throws -> JSONExportEntry {
        guard entries.count <= ScanExporter.maximumSnapshotEntries else {
            throw SnapshotImportError.resourceLimitExceeded(
                "snapshots may contain at most \(ScanExporter.maximumSnapshotEntries) entries"
            )
        }
        if let declaredRootPath {
            try validatePathLength(declaredRootPath)
        }
        guard diagnostics.unreadableItems >= 0,
              diagnostics.skippedDirectories >= 0,
              diagnostics.symbolicLinks >= 0,
              diagnostics.packages >= 0,
              diagnostics.duplicateHardLinks >= 0,
              diagnostics.revisitedDirectories >= 0 else {
            throw SnapshotImportError.invalidSnapshot("diagnostic counts cannot be negative")
        }
        guard diagnostics.firstUnreadablePaths.count <= 20 else {
            throw SnapshotImportError.invalidSnapshot("too many unreadable-path examples")
        }
        for path in diagnostics.firstUnreadablePaths {
            try Task.checkCancellation()
            try validatePathLength(path)
        }

        var entriesByPath: [SnapshotPathKey: JSONExportEntry] = [:]
        entriesByPath.reserveCapacity(entries.count)
        var childCountsByParent: [SnapshotPathKey: Int] = [:]
        var childLogicalSizesByParent: [SnapshotPathKey: Int64] = [:]
        var childAllocatedSizesByParent: [SnapshotPathKey: Int64] = [:]
        var root: JSONExportEntry?
        var rootCount = 0
        for entry in entries {
            try Task.checkCancellation()
            try validatePathLength(entry.path)
            try validatePathLength(entry.name)
            guard isCanonicalAbsolutePath(entry.path),
                  entry.allocatedSize >= 0,
                  entry.logicalSize >= 0,
                  entry.childCount >= 0,
                  (entry.totalFileCount ?? 0) >= 0,
                  (entry.totalDirectoryCount ?? 0) >= 0 else {
                throw SnapshotImportError.invalidSnapshot("entry values cannot be negative and paths must be absolute")
            }
            let key = SnapshotPathKey(entry.path)
            guard entriesByPath.updateValue(entry, forKey: key) == nil else {
                throw SnapshotImportError.invalidSnapshot("duplicate entry path: \(entry.path)")
            }
            if let parentPath = entry.parentPath {
                try validatePathLength(parentPath)
                let parentKey = SnapshotPathKey(parentPath)
                guard isCanonicalAbsolutePath(parentPath),
                      key != parentKey,
                      lexicalParent(of: entry.path).map(SnapshotPathKey.init) == parentKey else {
                    throw SnapshotImportError.invalidSnapshot("entry path does not match its parent: \(entry.path)")
                }
                childCountsByParent[parentKey, default: 0] += 1
                childLogicalSizesByParent[parentKey] = saturatingAddition(
                    childLogicalSizesByParent[parentKey, default: 0],
                    entry.logicalSize
                )
                childAllocatedSizesByParent[parentKey] = saturatingAddition(
                    childAllocatedSizesByParent[parentKey, default: 0],
                    entry.allocatedSize
                )
            } else {
                root = entry
                rootCount += 1
            }
        }

        guard let root else {
            throw SnapshotImportError.missingRoot
        }
        guard rootCount == 1, root.kind == .directory else {
            throw SnapshotImportError.invalidSnapshot("the snapshot must contain one directory root")
        }
        if let declaredRootPath,
           SnapshotPathKey(declaredRootPath) != SnapshotPathKey(root.path) {
            throw SnapshotImportError.invalidSnapshot("root path does not match the root entry")
        }

        for (key, entry) in entriesByPath {
            try Task.checkCancellation()
            if let parentPath = entry.parentPath {
                guard let parent = entriesByPath[SnapshotPathKey(parentPath)],
                      parent.kind == .directory || parent.kind == .package else {
                    throw SnapshotImportError.invalidSnapshot("entry has an invalid parent: \(entry.path)")
                }
            }
            guard entry.childCount == childCountsByParent[key, default: 0] else {
                throw SnapshotImportError.invalidSnapshot("child count does not match: \(entry.path)")
            }
            if entry.kind == .directory || entry.childCount > 0 {
                guard entry.logicalSize == childLogicalSizesByParent[key, default: 0],
                      entry.allocatedSize == childAllocatedSizesByParent[key, default: 0] else {
                    throw SnapshotImportError.invalidSnapshot(
                        "directory size does not match its children: \(entry.path)"
                    )
                }
            }
        }

        return root
    }

    private static func validatePathLength(_ value: String) throws {
        guard value.utf8.count <= ScanExporter.maximumSnapshotPathBytes else {
            throw SnapshotImportError.resourceLimitExceeded(
                "paths may be at most \(ScanExporter.maximumSnapshotPathBytes) UTF-8 bytes"
            )
        }
    }

    private static func lexicalParent(of path: String) -> String? {
        guard path != "/", let separator = path.lastIndex(of: "/") else { return nil }
        if separator == path.startIndex { return "/" }
        return String(path[..<separator])
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if path == "/" { return true }
        guard !path.hasSuffix("/"), !path.contains("//") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            $0 != "." && $0 != ".."
        }
    }
}

enum ScanSnapshotComparator {
    enum ComparisonError: LocalizedError {
        case rootMismatch(expected: String, actual: String)
        case optionsMismatch

        var errorDescription: String? {
            switch self {
            case .rootMismatch(let expected, let actual):
                return "This snapshot is for \(expected), but the current scan is \(actual). Scan the same location before comparing."
            case .optionsMismatch:
                return "The snapshot used different scan options. Repeat the scan with matching options before comparing."
            }
        }
    }

    static func compare(
        current root: FileNode,
        options: ScanOptions,
        diagnostics: ScanDiagnostics,
        with baseline: ImportedScanSnapshot
    ) throws -> ScanComparison {
        guard (2...4).contains(baseline.schemaVersion) else {
            throw SnapshotImportError.unsupportedSchema(baseline.schemaVersion)
        }
        if baseline.schemaVersion == 4, baseline.options == nil {
            throw SnapshotImportError.invalidSnapshot("schema 4 requires scan options")
        }
        if !baseline.isValidated {
            _ = try ScanSnapshotValidator.validate(
                entries: baseline.entries,
                declaredRootPath: baseline.rootPath,
                diagnostics: baseline.diagnostics
            )
        }
#if os(Linux)
        let currentRootPath = root.path
        let baselineRootPath = baseline.rootPath
#else
        let currentRootPath = root.url.standardizedFileURL.path
        let baselineRootPath = URL(fileURLWithPath: baseline.rootPath).standardizedFileURL.path
#endif
        guard SnapshotPathKey(currentRootPath) == SnapshotPathKey(baselineRootPath) else {
            throw ComparisonError.rootMismatch(expected: baselineRootPath, actual: currentRootPath)
        }
        if let baselineOptions = baseline.options, baselineOptions != options {
            throw ComparisonError.optionsMismatch
        }

        var baselineEntries: [SnapshotPathKey: JSONExportEntry] = [:]
        baselineEntries.reserveCapacity(baseline.entries.count)
        var baselineRootSize: Int64 = 0
        for entry in baseline.entries {
            try Task.checkCancellation()
            if entry.parentPath == nil {
                baselineRootSize = entry.allocatedSize
            }
            if entry.kind != .directory {
                baselineEntries[SnapshotPathKey(entry.path)] = entry
            }
        }

        var growth: [ScanChange] = []
        var shrinkage: [ScanChange] = []
        var addedCount = 0
        var removedCount = 0
        var changedCount = 0

        var stack = [ComparisonTraversalFrame(node: root)]
        var currentEntryCount = 0
        while !stack.isEmpty {
            try Task.checkCancellation()
            let frameIndex = stack.count - 1
            if !stack[frameIndex].didVisitNode {
                stack[frameIndex].didVisitNode = true
                currentEntryCount += 1
                guard currentEntryCount <= ScanExporter.maximumSnapshotEntries else {
                    throw SnapshotImportError.resourceLimitExceeded(
                        "comparisons may contain at most \(ScanExporter.maximumSnapshotEntries) current entries"
                    )
                }
                let node = stack[frameIndex].node
                if !node.isDirectory {
                    let key = SnapshotPathKey(node.path)
                    if let previous = baselineEntries.removeValue(forKey: key) {
                        if previous.allocatedSize != node.allocatedSize {
                            changedCount += 1
                            let change = ScanChange(
                                path: node.path,
                                kind: node.allocatedSize > previous.allocatedSize ? .grew : .shrank,
                                previousSize: previous.allocatedSize,
                                currentSize: node.allocatedSize,
                                currentNode: node
                            )
                            if change.delta > 0 {
                                append(change, to: &growth, keepsGrowth: true)
                            } else {
                                append(change, to: &shrinkage, keepsGrowth: false)
                            }
                        }
                    } else {
                        addedCount += 1
                        append(ScanChange(
                            path: node.path,
                            kind: .added,
                            previousSize: 0,
                            currentSize: node.allocatedSize,
                            currentNode: node
                        ), to: &growth, keepsGrowth: true)
                    }
                }
                continue
            }

            let node = stack[frameIndex].node
            let childIndex = stack[frameIndex].nextChildIndex
            guard childIndex < node.children.count else {
                stack.removeLast()
                continue
            }
            stack[frameIndex].nextChildIndex += 1
            stack.append(ComparisonTraversalFrame(node: node.children[childIndex]))
        }

        for previous in baselineEntries.values {
            try Task.checkCancellation()
            removedCount += 1
            append(ScanChange(
                path: previous.path,
                kind: .removed,
                previousSize: previous.allocatedSize,
                currentSize: 0,
                currentNode: nil
            ), to: &shrinkage, keepsGrowth: false)
        }

        trim(&growth, keepsGrowth: true, force: true)
        trim(&shrinkage, keepsGrowth: false, force: true)

        var reliabilityNotes: [String] = []
        if baseline.options == nil {
            reliabilityNotes.append(
                "This legacy snapshot does not record scan options, so differences may reflect a different scan scope."
            )
        }
        if hasIncompleteCoverage(diagnostics) || hasIncompleteCoverage(baseline.diagnostics) {
            reliabilityNotes.append(
                "The current scan or baseline has incomplete coverage, so comparison totals may be understated."
            )
        }

        return ScanComparison(
            baselineDate: baseline.exportedAt,
            rootPath: currentRootPath,
            totalDelta: saturatingDifference(root.allocatedSize, baselineRootSize),
            addedCount: addedCount,
            removedCount: removedCount,
            changedCount: changedCount,
            largestGrowth: growth,
            largestShrinkage: shrinkage,
            baselineDiagnostics: baseline.diagnostics,
            reliabilityWarning: reliabilityNotes.isEmpty
                ? nil
                : reliabilityNotes.joined(separator: " ")
        )
    }

    private static func append(
        _ change: ScanChange,
        to changes: inout [ScanChange],
        keepsGrowth: Bool
    ) {
        changes.append(change)
        if changes.count >= 512 {
            trim(&changes, keepsGrowth: keepsGrowth, force: false)
        }
    }

    private static func trim(
        _ changes: inout [ScanChange],
        keepsGrowth: Bool,
        force: Bool
    ) {
        guard force || changes.count >= 512 else { return }
        changes.sort {
            if $0.delta == $1.delta { return $0.path < $1.path }
            return keepsGrowth ? $0.delta > $1.delta : $0.delta < $1.delta
        }
        if changes.count > 100 {
            changes.removeSubrange(100...)
        }
    }

    private static func hasIncompleteCoverage(_ diagnostics: ScanDiagnostics) -> Bool {
        diagnostics.unreadableItems > 0 ||
            diagnostics.skippedDirectories > 0 ||
            diagnostics.revisitedDirectories > 0
    }
}

private struct ComparisonTraversalFrame {
    let node: FileNode
    var didVisitNode = false
    var nextChildIndex = 0
}

private struct SnapshotPathKey: Hashable {
#if os(Linux)
    let value: Data

    init(_ path: String) {
        value = Data(path.utf8)
    }
#else
    let value: String

    init(_ path: String) {
        value = path
    }
#endif
}

private func saturatingDifference(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
    guard overflow else { return result }
    return lhs >= rhs ? .max : .min
}

private func saturatingAddition(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : result
}
