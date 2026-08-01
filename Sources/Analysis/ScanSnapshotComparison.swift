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
    var delta: Int64 { currentSize - previousSize }
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

enum ScanSnapshotComparator {
    enum ComparisonError: LocalizedError {
        case rootMismatch(expected: String, actual: String)
        case optionsMismatch
        case optionsUnavailable
        case incompleteScan

        var errorDescription: String? {
            switch self {
            case .rootMismatch(let expected, let actual):
                return "This snapshot is for \(expected), but the current scan is \(actual). Scan the same location before comparing."
            case .optionsMismatch:
                return "The snapshot used different scan options. Repeat the scan with matching options before comparing."
            case .optionsUnavailable:
                return "This older snapshot does not record scan options. Create a new snapshot before comparing."
            case .incompleteScan:
                return "The current scan or snapshot contains unreadable items, so a reliable comparison cannot be produced."
            }
        }
    }

    static func compare(
        current root: FileNode,
        options: ScanOptions,
        diagnostics: ScanDiagnostics,
        with baseline: ImportedScanSnapshot
    ) throws -> ScanComparison {
        let currentRootPath = root.path
#if os(Linux)
        let baselineRootPath = baseline.rootPath
#else
        let baselineRootPath = URL(fileURLWithPath: baseline.rootPath).standardizedFileURL.path
#endif
        guard pathKey(currentRootPath) == pathKey(baselineRootPath) else {
            throw ComparisonError.rootMismatch(expected: baselineRootPath, actual: currentRootPath)
        }
        guard let baselineOptions = baseline.options else {
            throw ComparisonError.optionsUnavailable
        }
        if baselineOptions != options {
            throw ComparisonError.optionsMismatch
        }
        guard diagnostics.unreadableItems == 0,
              baseline.diagnostics.unreadableItems == 0 else {
            throw ComparisonError.incompleteScan
        }

        var currentEntries: [Data: FileNode] = [:]
        var stack = [root]
        while let node = stack.popLast() {
            if node.isDirectory {
                stack.append(contentsOf: node.children)
            } else {
                currentEntries[pathKey(node.path)] = node
            }
        }

        var baselineEntries: [Data: JSONExportEntry] = [:]
        for entry in baseline.entries where entry.kind != .directory {
            baselineEntries[pathKey(entry.path)] = entry
        }

        var growth: [ScanChange] = []
        var shrinkage: [ScanChange] = []
        var addedCount = 0
        var removedCount = 0
        var changedCount = 0

        for (key, node) in currentEntries {
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
            totalDelta: root.allocatedSize - baselineRootSize,
            addedCount: addedCount,
            removedCount: removedCount,
            changedCount: changedCount,
            largestGrowth: Array(growth.prefix(100)),
            largestShrinkage: Array(shrinkage.prefix(100)),
            baselineDiagnostics: baseline.diagnostics
        )
    }

    private static func pathKey(_ path: String) -> Data {
        Data(path.utf8)
    }
}
