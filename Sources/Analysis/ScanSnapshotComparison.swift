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

        var errorDescription: String? {
            switch self {
            case .rootMismatch(let expected, let actual):
                return "This snapshot is for \(expected), but the current scan is \(actual). Scan the same location before comparing."
            }
        }
    }

    static func compare(current root: FileNode, with baseline: ImportedScanSnapshot) throws -> ScanComparison {
        let currentRootPath = root.url.standardizedFileURL.path
        let baselineRootPath = URL(fileURLWithPath: baseline.rootPath).standardizedFileURL.path
        guard currentRootPath == baselineRootPath else {
            throw ComparisonError.rootMismatch(expected: baselineRootPath, actual: currentRootPath)
        }

        var currentEntries: [String: FileNode] = [:]
        var stack = [root]
        while let node = stack.popLast() {
            if node.isDirectory {
                stack.append(contentsOf: node.children)
            } else {
                currentEntries[node.path] = node
            }
        }

        var baselineEntries: [String: JSONExportEntry] = [:]
        for entry in baseline.entries where entry.kind != .directory {
            baselineEntries[entry.path] = entry
        }

        var growth: [ScanChange] = []
        var shrinkage: [ScanChange] = []
        var addedCount = 0
        var removedCount = 0
        var changedCount = 0

        for (path, node) in currentEntries {
            if let previous = baselineEntries[path] {
                guard previous.allocatedSize != node.allocatedSize else { continue }
                changedCount += 1
                let change = ScanChange(
                    path: path,
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
                    path: path,
                    kind: .added,
                    previousSize: 0,
                    currentSize: node.allocatedSize,
                    currentNode: node
                ))
            }
        }

        for (path, previous) in baselineEntries where currentEntries[path] == nil {
            removedCount += 1
            shrinkage.append(ScanChange(
                path: path,
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
}
