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
import SwiftUI

struct ExtensionStat: Identifiable, Hashable, Sendable {
    var id: String { ext }
    let ext: String
    let totalSize: Int64
    let fileCount: Int
    let color: Color
}

@MainActor
class AppViewModel: ObservableObject {
    @Published var rootNode: FileNode?
    @Published var currentNode: FileNode?
    @Published var selectedNode: FileNode?
    @Published var isScanning = false
    @Published var scanProgress: Double = 0
    @Published var totalFiles = 0
    @Published var totalDirectories = 0
    @Published var scanDuration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var viewMode: ViewMode = .treemap
    @Published var sortOrder: SortOrder = .sizeDescending
    @Published var searchQuery = ""
    @Published var extensionStats: [ExtensionStat] = []
    @Published var selectedExtension: String? = nil
    
    enum ViewMode: String, CaseIterable {
        case treemap = "Treemap"
        case list = "List"
        
        var icon: String {
            switch self {
            case .treemap: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
    }
    
    enum SortOrder: String, CaseIterable {
        case sizeDescending = "Size (Large First)"
        case sizeAscending = "Size (Small First)"
        case nameAscending = "Name (A-Z)"
        case nameDescending = "Name (Z-A)"
        
        var icon: String {
            switch self {
            case .sizeDescending: return "arrow.down"
            case .sizeAscending: return "arrow.up"
            case .nameAscending: return "textformat.abc"
            case .nameDescending: return "textformat.abc.dottedunderline"
            }
        }
    }
    
    private var scanner: DiskScanner?
    
    var filteredChildren: [FileNode] {
        guard let node = currentNode else { return [] }
        let baseChildren = node.children
        
        let filtered: [FileNode]
        if searchQuery.isEmpty {
            filtered = baseChildren
        } else {
            var results: [FileNode] = []
            func search(_ n: FileNode) {
                if n.displayName.localizedCaseInsensitiveContains(searchQuery) {
                    results.append(n)
                }
                for child in n.children {
                    search(child)
                }
            }
            for child in baseChildren {
                search(child)
            }
            filtered = results
        }
        
        switch sortOrder {
        case .sizeDescending:
            return filtered.sorted { $0.size > $1.size }
        case .sizeAscending:
            return filtered.sorted { $0.size < $1.size }
        case .nameAscending:
            return filtered.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .nameDescending:
            return filtered.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedDescending }
        }
    }
    
    var breadcrumb: [FileNode] {
        var path: [FileNode] = []
        var node: FileNode? = currentNode
        while let n = node {
            path.insert(n, at: 0)
            node = n.parent
        }
        return path
    }
    
    func scan(url: URL) {
        isScanning = true
        scanProgress = 0
        totalFiles = 0
        totalDirectories = 0
        scanDuration = 0
        errorMessage = nil
        showError = false
        rootNode = nil
        currentNode = nil
        selectedNode = nil
        
        Task {
            let scanner = DiskScanner()
            self.scanner = scanner
            
            do {
                let result = try await scanner.scan(url: url) { [weak self] snapshot in
                    guard let self = self else { return }
                    self.totalFiles = snapshot.files
                    self.totalDirectories = snapshot.directories
                    // Show the root node as soon as we have progress
                    if self.rootNode == nil {
                        self.rootNode = snapshot.currentNode.root()
                        self.currentNode = self.rootNode
                    }
                }
                
                 self.rootNode = result.root
                self.currentNode = result.root
                self.totalFiles = result.totalFiles
                self.totalDirectories = result.totalDirectories
                self.scanDuration = result.duration
                self.calculateExtensionStats()
                self.isScanning = false
                
            } catch {
                self.isScanning = false
                if let scanError = error as? DiskScanner.ScanError, scanError == .cancelled {
                    return
                }
                self.errorMessage = error.localizedDescription
                self.showError = true
            }
        }
    }
    
    func cancelScan() {
        Task {
            await scanner?.cancel()
        }
        isScanning = false
    }
    
    func navigateTo(node: FileNode) {
        if node.isDirectory {
            currentNode = node
            selectedNode = nil
        } else {
            selectedNode = node
        }
    }
    
    func navigateUp() {
        if let parent = currentNode?.parent {
            currentNode = parent
            selectedNode = nil
        }
    }
    
    func navigateToRoot() {
        currentNode = rootNode
        selectedNode = nil
    }
    
    func revealInFinder(node: FileNode) {
        NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "")
    }
    
    func openFile(node: FileNode) {
        NSWorkspace.shared.open(node.url)
    }
    
    func moveToTrash(node: FileNode) {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            if let parent = node.parent {
                parent.children.removeAll { $0.id == node.id }
                parent.size = parent.children.reduce(0) { $0 + $1.size }
                if parent.children.isEmpty {
                    parent.size = 0
                }
                objectWillChange.send()
            }
            calculateExtensionStats()
        } catch {
            errorMessage = "Failed to move to trash: \(error.localizedDescription)"
            showError = true
        }
    }
    
    func calculateExtensionStats() {
        guard let root = rootNode else {
            self.extensionStats = []
            return
        }
        
        Task {
            let stats = await Task.detached(priority: .userInitiated) {
                var localStats: [String: (size: Int64, count: Int)] = [:]
                
                func traverse(_ node: FileNode) {
                    if node.isDirectory {
                        for child in node.children {
                            traverse(child)
                        }
                    } else {
                        let ext = (node.extension ?? "Unknown").lowercased()
                        let current = localStats[ext, default: (0, 0)]
                        localStats[ext] = (current.size + node.size, current.count + 1)
                    }
                }
                
                traverse(root)
                
                return localStats.map { (ext, value) in
                    ExtensionStat(
                        ext: ext,
                        totalSize: value.size,
                        fileCount: value.count,
                        color: FileTypeColors.color(forExtension: ext)
                    )
                }.sorted { $0.totalSize > $1.totalSize }
            }.value
            
            self.extensionStats = stats
        }
    }
}
