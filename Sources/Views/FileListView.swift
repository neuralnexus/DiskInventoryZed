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

import SwiftUI

struct FileListView: View {
    let node: FileNode
    @EnvironmentObject var viewModel: AppViewModel
    
    var body: some View {
        List(viewModel.filteredChildren, selection: selectedNodeBinding) { child in
            FileListRow(node: child)
                .tag(child)
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.navigateTo(node: child)
                }
                .onDrag {
                    NSItemProvider(object: child.url as NSURL)
                }
        }
        .listStyle(.plain)
        .contextMenuForSelection(of: FileNode.self) { items in
            if let first = items.first {
                Button("Open File / Folder") {
                    viewModel.openFile(node: first)
                }
                
                Button("Reveal in Finder") {
                    viewModel.revealInFinder(node: first)
                }
                
                Button("Open Containing Folder") {
                    viewModel.openContainingFolder(node: first)
                }
                
                if !first.isDirectory {
                    Button("Move to Trash") {
                        viewModel.moveToTrash(node: first)
                    }
                }
                
                Divider()
                
                if first.isDirectory {
                    Button("Scan This Folder") {
                        viewModel.scan(url: first.url)
                    }
                }
            }
        }
    }
    
    private var selectedNodeBinding: Binding<FileNode?> {
        Binding(
            get: { viewModel.selectedNode },
            set: { node in
                if let node = node {
                    viewModel.selectedNode = node
                }
            }
        )
    }
}

struct FileListRow: View {
    let node: FileNode
    @EnvironmentObject var viewModel: AppViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .foregroundStyle(FileTypeColors.color(for: node))
                .font(.system(size: 16))
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                
                if let ext = node.extension {
                    Text(ext.uppercased())
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(node.formattedSize)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                
                if let date = node.modificationDate {
                    Text(date, style: .date)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Open File / Folder") {
                viewModel.openFile(node: node)
            }
            
            Button("Reveal in Finder") {
                viewModel.revealInFinder(node: node)
            }
            
            Button("Open Containing Folder") {
                viewModel.openContainingFolder(node: node)
            }
            
            if !node.isDirectory {
                Button("Move to Trash") {
                    viewModel.moveToTrash(node: node)
                }
            }
            
            Divider()
            
            if node.isDirectory {
                Button("Scan This Folder") {
                    viewModel.scan(url: node.url)
                }
            }
        }
    }
}

extension View {
    @ViewBuilder
    func contextMenuForSelection<T: Identifiable>(
        of type: T.Type,
        @ViewBuilder content: @escaping (Set<T>) -> some View
    ) -> some View where T: Hashable {
        if #available(macOS 14.0, *) {
            self.contextMenu(forSelectionType: T.self, menu: { items in
                content(items)
            }, primaryAction: { _ in })
        } else {
            self
        }
    }
}
