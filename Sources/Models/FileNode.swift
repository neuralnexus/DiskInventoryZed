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

final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let modificationDate: Date?
    let creationDate: Date?
    let `extension`: String?
    
    var size: Int64 = 0
    var children: [FileNode] = []
    weak var parent: FileNode?
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    var isLeaf: Bool {
        !isDirectory || children.isEmpty
    }
    
    var directoryChildren: [FileNode]? {
        let dirs = children.filter { $0.isDirectory }
        return dirs.isEmpty ? nil : dirs
    }
    
    var displayName: String {
        if name.isEmpty { return url.path }
        return name
    }
    
    var path: String {
        url.path
    }
    
    var depth: Int {
        var count = 0
        var node: FileNode? = parent
        while node != nil {
            count += 1
            node = node?.parent
        }
        return count
    }
    
    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    init(url: URL, name: String, isDirectory: Bool, modificationDate: Date? = nil, creationDate: Date? = nil, extension: String? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.extension = `extension`
    }
    
    func root() -> FileNode {
        var node = self
        while let parent = node.parent {
            node = parent
        }
        return node
    }
    
    func findChild(at url: URL) -> FileNode? {
        if self.url == url { return self }
        for child in children {
            if let found = child.findChild(at: url) {
                return found
            }
        }
        return nil
    }
}
