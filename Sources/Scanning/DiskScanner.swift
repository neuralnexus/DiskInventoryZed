// Disk Inventory Zed — a modern, fast, native disk usage visualizer
// https://github.com/yourusername/DiskInventoryZed
//
// Copyright (C) 2026 Matt Ivan
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation

actor DiskScanner {
    enum ScanError: Error {
        case accessDenied
        case invalidURL
        case cancelled
    }
    
    struct ScanResult {
        let root: FileNode
        let totalFiles: Int
        let totalDirectories: Int
        let duration: TimeInterval
    }
    
    struct ProgressSnapshot {
        let currentNode: FileNode
        let files: Int
        let directories: Int
    }
    
    private var isCancelled = false
    
    func cancel() {
        isCancelled = true
    }
    
    /// Scans a directory concurrently with throttled progress reporting.
    /// Processes all children (files and directories) in parallel across all CPU cores.
    func scan(
        url: URL,
        skipDeveloperFolders: Bool = false,
        progressHandler: @escaping @MainActor (ProgressSnapshot) -> Void
    ) async throws -> ScanResult {
        isCancelled = false
        let startTime = Date()
        
        let root = FileNode(
            url: url,
            name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            isDirectory: true
        )
        
        let fileManager = FileManager.default
        
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isHiddenKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .isPackageKey,
            .isSymbolicLinkKey
        ]
        
        let progress = ProgressTracker()
        
        // Start a background task that reports progress every 100ms
        let progressTask = Task { @MainActor in
            var lastFiles = 0
            var lastDirs = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                let trackerSnapshot = await progress.getSnapshot()
                if trackerSnapshot.files != lastFiles || trackerSnapshot.directories != lastDirs {
                    lastFiles = trackerSnapshot.files
                    lastDirs = trackerSnapshot.directories
                    let snapshot = ProgressSnapshot(
                        currentNode: trackerSnapshot.currentNode ?? root,
                        files: trackerSnapshot.files,
                        directories: trackerSnapshot.directories
                    )
                    progressHandler(snapshot)
                }
            }
        }
        
        // Scan a single node: list children, then process all children
        func scanNode(_ node: FileNode, depth: Int) async throws {
            if isCancelled {
                progressTask.cancel()
                throw ScanError.cancelled
            }
            
            // Skip developer folders if configured
            if skipDeveloperFolders {
                let name = node.url.lastPathComponent.lowercased()
                if name == "node_modules" || name == ".git" || name == ".svn" || name == "deriveddata" {
                    return
                }
            }
            
            guard node.isDirectory else {
                if let values = try? node.url.resourceValues(forKeys: resourceKeys) {
                    let fileSize = values.totalFileAllocatedSize ?? values.fileSize ?? 0
                    node.size = Int64(fileSize)
                    await progress.incrementFiles()
                }
                return
            }
            
            await progress.incrementDirectories()
            
            let contents = try? fileManager.contentsOfDirectory(
                at: node.url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
            
            var childNodes: [FileNode] = []
            
            // First pass: create all child nodes (sequential, just property reads)
            for childURL in contents ?? [] {
                if isCancelled {
                    progressTask.cancel()
                    throw ScanError.cancelled
                }
                
                let values = try? childURL.resourceValues(forKeys: resourceKeys)
                let isDir = values?.isDirectory ?? false
                let isSymlink = values?.isSymbolicLink ?? false
                let isHidden = values?.isHidden ?? false
                
                if isHidden { continue }
                
                let childNode = FileNode(
                    url: childURL,
                    name: childURL.lastPathComponent,
                    isDirectory: isDir && !isSymlink, // Treat symlinks as files to prevent infinite loops
                    modificationDate: values?.contentModificationDate,
                    creationDate: values?.creationDate,
                    extension: childURL.pathExtension.isEmpty ? nil : childURL.pathExtension
                )
                
                childNode.parent = node
                childNodes.append(childNode)
            }
            
            // Second pass: process children.
            // Parallelize ONLY up to depth 2 to prevent thread-pool exhaustion/deadlock.
            if depth < 2 {
                await withTaskGroup(of: Void.self) { group in
                    for childNode in childNodes {
                        group.addTask {
                            if childNode.isDirectory {
                                try? await scanNode(childNode, depth: depth + 1)
                            } else {
                                let values = try? childNode.url.resourceValues(forKeys: resourceKeys)
                                let fileSize = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
                                childNode.size = Int64(fileSize)
                                await progress.incrementFiles()
                            }
                        }
                    }
                }
            } else {
                // Sequential scanning inside deep folders is extremely fast and completely deadlock-free
                for childNode in childNodes {
                    if childNode.isDirectory {
                        try? await scanNode(childNode, depth: depth + 1)
                    } else {
                        let values = try? childNode.url.resourceValues(forKeys: resourceKeys)
                        let fileSize = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
                        childNode.size = Int64(fileSize)
                        await progress.incrementFiles()
                    }
                }
            }
            
            node.children = childNodes.sorted { $0.size > $1.size }
            node.size = node.children.reduce(0) { $0 + $1.size }
            
            await progress.updateCurrentNode(node)
        }
        
        // Start the scan
        try await scanNode(root, depth: 0)
        
        // Cancel progress reporting
        progressTask.cancel()
        
        // Final progress update
        let trackerSnapshot = await progress.getSnapshot()
        let finalSnapshot = ProgressSnapshot(
            currentNode: root,
            files: trackerSnapshot.files,
            directories: trackerSnapshot.directories
        )
        await progressHandler(finalSnapshot)
        
        let duration = Date().timeIntervalSince(startTime)
        return ScanResult(
            root: root,
            totalFiles: trackerSnapshot.files,
            totalDirectories: trackerSnapshot.directories,
            duration: duration
        )
    }
}

// MARK: - Progress Tracking

private actor ProgressTracker {
    private var files = 0
    private var directories = 0
    private var currentNode: FileNode?
    private var pendingFiles = 0
    private var pendingDirectories = 0
    
    func incrementFiles() {
        pendingFiles += 1
        if pendingFiles >= 100 {
            files += pendingFiles
            pendingFiles = 0
        }
    }
    
    func incrementDirectories() {
        pendingDirectories += 1
        if pendingDirectories >= 10 {
            directories += pendingDirectories
            pendingDirectories = 0
        }
    }
    
    func updateCurrentNode(_ node: FileNode) {
        currentNode = node
    }
    
    struct Snapshot {
        let files: Int
        let directories: Int
        let currentNode: FileNode?
    }
    
    func getSnapshot() -> Snapshot {
        Snapshot(files: files + pendingFiles, directories: directories + pendingDirectories, currentNode: currentNode)
    }
}
