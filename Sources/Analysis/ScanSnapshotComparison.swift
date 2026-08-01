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
}

enum ScanSnapshotValidator {
    static func validate(
        entries: [JSONExportEntry],
        declaredRootPath: String?,
        diagnostics: ScanDiagnostics
    ) throws -> JSONExportEntry {
        let roots = entries.filter { $0.parentPath == nil }
        guard let root = roots.first else {
            throw SnapshotImportError.missingRoot
        }
        guard roots.count == 1, root.kind == .directory else {
            throw SnapshotImportError.invalidSnapshot("the snapshot must contain one directory root")
        }
        if let declaredRootPath,
           SnapshotPathKey(declaredRootPath) != SnapshotPathKey(root.path) {
            throw SnapshotImportError.invalidSnapshot("root path does not match the root entry")
        }
        guard diagnostics.unreadableItems >= 0,
              diagnostics.skippedDirectories >= 0,
              diagnostics.symbolicLinks >= 0,
              diagnostics.packages >= 0,
              diagnostics.duplicateHardLinks >= 0,
              diagnostics.revisitedDirectories >= 0 else {
            throw SnapshotImportError.invalidSnapshot("diagnostic counts cannot be negative")
        }

        var entriesByPath: [SnapshotPathKey: JSONExportEntry] = [:]
        entriesByPath.reserveCapacity(entries.count)
        var childrenByParent: [SnapshotPathKey: [SnapshotPathKey]] = [:]
        for entry in entries {
            try Task.checkCancellation()
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
                let parentKey = SnapshotPathKey(parentPath)
                guard isCanonicalAbsolutePath(parentPath),
                      key != parentKey,
                      lexicalParent(of: entry.path).map(SnapshotPathKey.init) == parentKey else {
                    throw SnapshotImportError.invalidSnapshot("entry path does not match its parent: \(entry.path)")
                }
                childrenByParent[parentKey, default: []].append(key)
            }
        }

        for (key, entry) in entriesByPath {
            try Task.checkCancellation()
            if let parentPath = entry.parentPath {
                guard let parent = entriesByPath[SnapshotPathKey(parentPath)],
                      parent.kind == .directory || parent.kind == .package else {
                    throw SnapshotImportError.invalidSnapshot("entry has an invalid parent: \(entry.path)")
                }
            }
            guard entry.childCount == childrenByParent[key, default: []].count else {
                throw SnapshotImportError.invalidSnapshot("child count does not match: \(entry.path)")
            }
        }

        var reachable: Set<SnapshotPathKey> = []
        var stack = [SnapshotPathKey(root.path)]
        while let key = stack.popLast() {
            try Task.checkCancellation()
            guard reachable.insert(key).inserted else { continue }
            stack.append(contentsOf: childrenByParent[key, default: []])
        }
        guard reachable.count == entries.count else {
            throw SnapshotImportError.invalidSnapshot("entries are disconnected from the root")
        }

        return root
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

        var errorDescription: String? {
            switch self {
            case .rootMismatch(let expected, let actual):
                return "This snapshot is for \(expected), but the current scan is \(actual). Scan the same location before comparing."
            }
        }
    }

    static func compare(current root: FileNode, with baseline: ImportedScanSnapshot) throws -> ScanComparison {
        guard (2...3).contains(baseline.schemaVersion) else {
            throw SnapshotImportError.unsupportedSchema(baseline.schemaVersion)
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
        _ = try ScanSnapshotValidator.validate(
            entries: baseline.entries,
            declaredRootPath: baseline.rootPath,
            diagnostics: baseline.diagnostics
        )

        var currentEntries: [SnapshotPathKey: FileNode] = [:]
        var stack = [root]
        while let node = stack.popLast() {
            try Task.checkCancellation()
            if node.isDirectory {
                stack.append(contentsOf: node.children)
            } else {
                currentEntries[SnapshotPathKey(node.path)] = node
            }
        }

        var baselineEntries: [SnapshotPathKey: JSONExportEntry] = [:]
        for entry in baseline.entries where entry.kind != .directory {
            try Task.checkCancellation()
            baselineEntries[SnapshotPathKey(entry.path)] = entry
        }

        var growth: [ScanChange] = []
        var shrinkage: [ScanChange] = []
        var addedCount = 0
        var removedCount = 0
        var changedCount = 0

        for (key, node) in currentEntries {
            try Task.checkCancellation()
            if let previous = baselineEntries[key] {
                guard previous.allocatedSize != node.allocatedSize else { continue }
                changedCount += 1
                let change = ScanChange(
                    path: node.path,
                    kind: node.allocatedSize > previous.allocatedSize ? .grew : .shrank,
                    previousSize: previous.allocatedSize,
                    currentSize: node.allocatedSize,
                    currentNode: node
                )
                if change.delta > 0 {
                    growth.append(change)
                } else {
                    shrinkage.append(change)
                }
            } else {
                addedCount += 1
                growth.append(ScanChange(
                    path: node.path,
                    kind: .added,
                    previousSize: 0,
                    currentSize: node.allocatedSize,
                    currentNode: node
                ))
            }
        }

        for (key, previous) in baselineEntries where currentEntries[key] == nil {
            try Task.checkCancellation()
            removedCount += 1
            shrinkage.append(ScanChange(
                path: previous.path,
                kind: .removed,
                previousSize: previous.allocatedSize,
                currentSize: 0,
                currentNode: nil
            ))
        }

        growth.sort {
            if $0.delta == $1.delta { return $0.path < $1.path }
            return $0.delta > $1.delta
        }
        shrinkage.sort {
            if $0.delta == $1.delta { return $0.path < $1.path }
            return $0.delta < $1.delta
        }

        let baselineRootSize = baseline.entries
            .first(where: { $0.parentPath == nil })?
            .allocatedSize ?? 0

        return ScanComparison(
            baselineDate: baseline.exportedAt,
            rootPath: currentRootPath,
            totalDelta: saturatingDifference(root.allocatedSize, baselineRootSize),
            addedCount: addedCount,
            removedCount: removedCount,
            changedCount: changedCount,
            largestGrowth: Array(growth.prefix(100)),
            largestShrinkage: Array(shrinkage.prefix(100)),
            baselineDiagnostics: baseline.diagnostics
        )
    }
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
