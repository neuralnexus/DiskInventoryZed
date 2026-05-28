// Disk Inventory Zed — a modern, fast, native disk usage visualizer
// https://github.com/mattivan/DiskInventoryZed
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

struct RightSidebarView: View {
    @EnvironmentObject var viewModel: AppViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Extension Legend Section
            VStack(alignment: .leading, spacing: 8) {
                Text("File Types")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                
                if viewModel.extensionStats.isEmpty {
                    Text("No file type statistics available")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    List(viewModel.extensionStats.prefix(30)) { stat in
                        ExtensionRow(stat: stat, isSelected: viewModel.selectedExtension == stat.ext)
                            .onTapGesture {
                                if viewModel.selectedExtension == stat.ext {
                                    viewModel.selectedExtension = nil
                                } else {
                                    viewModel.selectedExtension = stat.ext
                                }
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxHeight: .infinity)
            
            Divider()
            
            // File Details Inspector Section
            VStack(alignment: .leading, spacing: 10) {
                Text("Selection Details")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                
                let inspectNode = viewModel.selectedNode ?? viewModel.currentNode
                if let node = inspectNode {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: node.isDirectory ? "folder" : "doc")
                                .font(.system(size: 18))
                                .foregroundStyle(FileTypeColors.color(for: node))
                            
                            Text(node.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(2)
                        }
                        
                        Divider()
                        
                        Group {
                            DetailItem(label: "Kind", value: node.isDirectory ? "Folder" : "File")
                            DetailItem(label: "Size", value: node.formattedSize)
                            
                            if let ext = node.extension {
                                DetailItem(label: "Extension", value: ext.uppercased())
                            }
                            
                            if let modified = node.modificationDate {
                                DetailItem(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                            }
                            
                            if let created = node.creationDate {
                                DetailItem(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        
                        Spacer(minLength: 4)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Full Path")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            
                            Text(node.path)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                        .padding(.top, 4)
                        
                        HStack {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(node.path, forType: .string)
                            }) {
                                Label("Copy Path", systemImage: "doc.on.doc")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Button(action: {
                                viewModel.revealInFinder(node: node)
                            }) {
                                Label("In Finder", systemImage: "folder")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                } else {
                    Text("No item selected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
            .frame(height: 250)
            .background(Color.black.opacity(0.02))
        }
    }
}

struct ExtensionRow: View {
    let stat: ExtensionStat
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(stat.color)
                .frame(width: 14, height: 14)
            
            Text(stat.ext.isEmpty ? "No Ext" : stat.ext.uppercased())
                .font(.system(size: 11, weight: .medium))
            
            Spacer()
            
            Text("\(stat.fileCount) files")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            
            Text(ByteCountFormatter.string(fromByteCount: stat.totalSize, countStyle: .file))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
    }
}

struct DetailItem: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
        }
    }
}
