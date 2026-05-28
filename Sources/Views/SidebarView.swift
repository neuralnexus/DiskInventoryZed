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

struct SidebarView: View {
    @EnvironmentObject var viewModel: AppViewModel
    
    var body: some View {
        List(selection: selectedNodeBinding) {
            if let root = viewModel.rootNode {
                Section("Scanned Location") {
                    OutlineGroup(root, children: \.directoryChildren) { node in
                        SidebarRow(node: node)
                    }
                }
            }
            
            Section("Quick Access") {
                QuickAccessItem(title: "Home", path: FileManager.default.homeDirectoryForCurrentUser, icon: "house")
                QuickAccessItem(title: "Applications", path: URL(fileURLWithPath: "/Applications"), icon: "app")
                QuickAccessItem(title: "Documents", path: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first, icon: "doc.text")
                QuickAccessItem(title: "Downloads", path: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first, icon: "arrow.down.circle")
                QuickAccessItem(title: "Desktop", path: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first, icon: "desktopcomputer")
            }
            
            Section("Volumes") {
                ForEach(mountedVolumes, id: \.path) { volume in
                    QuickAccessItem(title: volume.name, path: volume.url, icon: "externaldrive")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 250)
    }
    
    private var selectedNodeBinding: Binding<FileNode?> {
        Binding(
            get: { viewModel.currentNode },
            set: { node in
                if let node = node {
                    viewModel.navigateTo(node: node)
                }
            }
        )
    }
    
    private var mountedVolumes: [(name: String, path: String, url: URL)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.volumeNameKey]),
                  let name = values.volumeName else { return nil }
            return (name: name, path: url.path, url: url)
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var viewModel: AppViewModel
    let node: FileNode
    
    var body: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(FileTypeColors.color(for: node))
            
            Text(node.displayName)
                .lineLimit(1)
            
            Spacer()
            
            Text(node.formattedSize)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(node)
        .contextMenu {
            Button("Open Folder") {
                viewModel.openFile(node: node)
            }
            
            Button("Reveal in Finder") {
                viewModel.revealInFinder(node: node)
            }
            
            Divider()
            
            Button("Scan This Folder") {
                viewModel.scan(url: node.url)
            }
        }
    }
}

struct QuickAccessItem: View {
    @EnvironmentObject var viewModel: AppViewModel
    let title: String
    let path: URL?
    let icon: String
    
    var body: some View {
        Button {
            if let path = path {
                viewModel.scan(url: path)
            }
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.plain)
        .disabled(path == nil)
    }
}
