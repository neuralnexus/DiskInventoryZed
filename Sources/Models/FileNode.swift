// Disk Inventory Zed — a modern, fast, native disk usage visualizer
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

import Foundation

/// An immutable snapshot of a file-system entry.
///
/// The scanner builds the complete graph off the main actor and only then publishes it.
/// Every stored property is immutable, so sharing a completed snapshot across actors is safe.
/// Keeping the node as a reference type avoids copying entire subtrees for navigation and search.
final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case directory
        case package
        case symbolicLink
    }

    let id: String
    let url: URL
    let name: String
    let kind: Kind
    let isPackage: Bool
    let isSymbolicLink: Bool
    let modificationDate: Date?
    let creationDate: Date?
    let `extension`: String?
    let logicalSize: Int64
    let allocatedSize: Int64
    let children: [FileNode]
    let errorDescription: String?
    let isHardLinkDuplicate: Bool
    let totalFileCount: Int
    let totalDirectoryCount: Int

    var size: Int64 { allocatedSize }
    var isDirectory: Bool { kind == .directory }
    var isUnreadable: Bool { errorDescription != nil }
    var isLeaf: Bool { children.isEmpty }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: allocatedSize, countStyle: .file)
    }

    var formattedLogicalSize: String {
        ByteCountFormatter.string(fromByteCount: logicalSize, countStyle: .file)
    }

    var directoryChildren: [FileNode]? {
        let directories = children.filter(\.isDirectory)
        return directories.isEmpty ? nil : directories
    }

    var displayName: String {
        name.isEmpty ? url.path : name
    }

    var path: String {
        url.path
    }

    init(
        id: String? = nil,
        url: URL,
        name: String,
        kind: Kind,
        isPackage: Bool? = nil,
        isSymbolicLink: Bool? = nil,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        extension: String? = nil,
        logicalSize: Int64,
        allocatedSize: Int64,
        children: [FileNode] = [],
        errorDescription: String? = nil,
        isHardLinkDuplicate: Bool = false,
        totalFileCount: Int? = nil,
        totalDirectoryCount: Int? = nil
    ) {
        self.id = id ?? url.standardizedFileURL.path
        self.url = url
        self.name = name
        self.kind = kind
        self.isPackage = isPackage ?? (kind == .package)
        self.isSymbolicLink = isSymbolicLink ?? (kind == .symbolicLink)
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.extension = `extension`
        self.logicalSize = max(0, logicalSize)
        self.allocatedSize = max(0, allocatedSize)
        self.children = children
        self.errorDescription = errorDescription
        self.isHardLinkDuplicate = isHardLinkDuplicate
        self.totalFileCount = totalFileCount ?? (
            kind == .directory
                ? children.reduce(0) { $0 + $1.totalFileCount }
                : 1
        )
        self.totalDirectoryCount = totalDirectoryCount ?? (
            kind == .directory
                ? 1 + children.reduce(0) { $0 + $1.totalDirectoryCount }
                : 0
        )
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func findChild(withID targetID: String) -> FileNode? {
        var stack = [self]
        while let node = stack.popLast() {
            if node.id == targetID { return node }
            stack.append(contentsOf: node.children.reversed())
        }
        return nil
    }

    func findChild(at targetURL: URL) -> FileNode? {
        findChild(withID: targetURL.standardizedFileURL.path)
    }

    func path(to targetID: String) -> [FileNode]? {
        var stack = [self]
        var nodesByID: [String: FileNode] = [id: self]
        var parentByID: [String: String] = [:]

        while let node = stack.popLast() {
            if node.id == targetID {
                var result: [FileNode] = []
                var cursor: String? = targetID
                while let currentID = cursor,
                      let currentNode = nodesByID[currentID] {
                    result.append(currentNode)
                    cursor = parentByID[currentID]
                }
                return Array(result.reversed())
            }

            for child in node.children.reversed() {
                nodesByID[child.id] = child
                parentByID[child.id] = node.id
                stack.append(child)
            }
        }
        return nil
    }

    /// Returns a new immutable tree with the requested item removed.
    /// Only ancestors of the removed item are rebuilt.
    func removingDescendant(withID targetID: String) -> FileNode {
        guard targetID != id,
              let targetPath = path(to: targetID),
              targetPath.count > 1 else {
            return self
        }

        var replacement: FileNode?
        for ancestor in targetPath.dropLast().reversed() {
            let childToReplaceID = replacement?.id ?? targetID
            let updatedChildren = ancestor.children.compactMap { child -> FileNode? in
                guard child.id == childToReplaceID else { return child }
                return replacement
            }
            replacement = ancestor.replacingChildren(updatedChildren)
        }
        return replacement ?? self
    }

    func descendantCounts() -> (files: Int, directories: Int) {
        (totalFileCount, totalDirectoryCount)
    }

    private func replacingChildren(_ updatedChildren: [FileNode]) -> FileNode {
        let newLogicalSize = updatedChildren.reduce(Int64(0)) { $0 + $1.logicalSize }
        let newAllocatedSize = updatedChildren.reduce(Int64(0)) { $0 + $1.allocatedSize }

        return FileNode(
            id: id,
            url: url,
            name: name,
            kind: kind,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            modificationDate: modificationDate,
            creationDate: creationDate,
            extension: `extension`,
            logicalSize: isDirectory ? newLogicalSize : logicalSize,
            allocatedSize: isDirectory ? newAllocatedSize : allocatedSize,
            children: updatedChildren,
            errorDescription: errorDescription,
            isHardLinkDuplicate: isHardLinkDuplicate,
            totalFileCount: updatedChildren.reduce(0) { $0 + $1.totalFileCount },
            totalDirectoryCount: 1 + updatedChildren.reduce(0) { $0 + $1.totalDirectoryCount }
        )
    }
}
