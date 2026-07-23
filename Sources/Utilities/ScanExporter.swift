// Disk Inventory Zed — scan export support
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

import Foundation

enum ScanExporter {
    /// Writes a reconstructable flat JSON document without first duplicating the entire
    /// in-memory tree. This keeps exports safe for scans containing millions of entries.
    static func exportJSON(root: FileNode, diagnostics: ScanDiagnostics, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        try writeAtomically(to: url) { handle in
            let formatter = ISO8601DateFormatter()
            let encodedDiagnostics = try encoder.encode(JSONDiagnostics(diagnostics))
            let prefix = """
            {"schemaVersion":2,"exportedAt":\(jsonString(formatter.string(from: Date()))),"diagnostics":
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

    static func exportCSV(root: FileNode, to url: URL) throws {
        try writeAtomically(to: url) { handle in
            try write(
                "path,parent_path,name,kind,is_package,is_symbolic_link,allocated_bytes,logical_bytes,child_count,created_at,modified_at,hard_link_duplicate,issue\n",
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
        let fileManager = FileManager.default
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")

        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            do {
                let handle = try FileHandle(forWritingTo: temporaryURL)
                defer { handle.closeFile() }
                try body(handle)
                handle.synchronizeFile()
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
    }

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

private struct JSONDiagnostics: Codable {
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
}

private struct JSONExportEntry: Codable {
    let path: String
    let parentPath: String?
    let name: String
    let kind: FileNode.Kind
    let isPackage: Bool
    let isSymbolicLink: Bool
    let allocatedSize: Int64
    let logicalSize: Int64
    let childCount: Int
    let creationDate: Date?
    let modificationDate: Date?
    let isHardLinkDuplicate: Bool
    let issue: String?

    init(node: FileNode, parentPath: String?) {
        path = node.path
        self.parentPath = parentPath
        name = node.displayName
        kind = node.kind
        isPackage = node.isPackage
        isSymbolicLink = node.isSymbolicLink
        allocatedSize = node.allocatedSize
        logicalSize = node.logicalSize
        childCount = node.children.count
        creationDate = node.creationDate
        modificationDate = node.modificationDate
        isHardLinkDuplicate = node.isHardLinkDuplicate
        issue = node.errorDescription
    }
}
