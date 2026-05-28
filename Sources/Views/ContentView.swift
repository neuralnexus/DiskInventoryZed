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
import QuickLook

struct ContentView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showFilePicker = false
    @State private var quickLookURL: URL?
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ToolbarView()
                    
                    if viewModel.isScanning {
                        ScanningView()
                    } else if let node = viewModel.currentNode {
                        if viewModel.viewMode == .treemap {
                            TreemapView(node: node)
                        } else {
                            FileListView(node: node)
                        }
                    } else {
                        EmptyStateView()
                    }
                    
                    StatusBarView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                if viewModel.rootNode != nil && !viewModel.isScanning {
                    Divider()
                    RightSidebarView()
                        .frame(width: 320)
                        .background(.ultraThinMaterial)
                }
            }
        }
        .searchable(text: $viewModel.searchQuery, prompt: "Search files...")
        .quickLookPreview($quickLookURL)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button(action: {
                        if let selected = viewModel.selectedNode ?? viewModel.currentNode {
                            quickLookURL = selected.url
                        }
                    }) {
                        Label("Preview", systemImage: "eye")
                    }
                    .disabled(viewModel.selectedNode == nil && viewModel.currentNode == nil)
                    .help("Quick Look Selected Item")
                    
                    Button(action: { showFilePicker = true }) {
                        Label("Scan Folder", systemImage: "folder.badge.plus")
                    }
                    .disabled(viewModel.isScanning)
                }
            }
            
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { viewModel.navigateUp() }) {
                    Label("Back", systemImage: "arrow.up")
                }
                .disabled(viewModel.currentNode?.parent == nil)
                
                Button(action: { viewModel.navigateToRoot() }) {
                    Label("Root", systemImage: "arrow.up.to.line")
                }
                .disabled(viewModel.currentNode == viewModel.rootNode)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewModel.scan(url: url)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { viewModel.showError = false }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }
}

struct ToolbarView: View {
    @EnvironmentObject var viewModel: AppViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(viewModel.breadcrumb) { node in
                    if node.id != viewModel.breadcrumb.first?.id {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Button(node.displayName) {
                        viewModel.navigateTo(node: node)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(node.id == viewModel.currentNode?.id ? .primary : .secondary)
                    .font(.system(size: 12, weight: node.id == viewModel.currentNode?.id ? .semibold : .regular))
                }
            }
            
            Spacer()
            
            Picker("View", selection: $viewModel.viewMode) {
                ForEach(AppViewModel.ViewMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.icon)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            
            Picker("Sort", selection: $viewModel.sortOrder) {
                ForEach(AppViewModel.SortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 140, idealWidth: 180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct ScanningView: View {
    @EnvironmentObject var viewModel: AppViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Scanning...")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(spacing: 4) {
                Text("\(viewModel.totalFiles) files, \(viewModel.totalDirectories) directories")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Button("Cancel") {
                viewModel.cancelScan()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showFilePicker = false
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            Text("Disk Inventory Zed")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Select a folder to analyze its disk usage")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Button("Choose Folder...") {
                showFilePicker = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
            
            HStack(spacing: 12) {
                QuickScanButton(title: "Home", path: FileManager.default.homeDirectoryForCurrentUser, icon: "house")
                QuickScanButton(title: "Applications", path: URL(fileURLWithPath: "/Applications"), icon: "app")
                QuickScanButton(title: "Documents", path: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first, icon: "doc.text")
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewModel.scan(url: url)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
    }
}

struct QuickScanButton: View {
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
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(width: 100, height: 80)
            .background(.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(path == nil)
    }
}

struct StatusBarView: View {
    @EnvironmentObject var viewModel: AppViewModel
    
    var body: some View {
        HStack(spacing: 16) {
            if let node = viewModel.currentNode {
                HStack(spacing: 4) {
                    Text("Size:")
                        .foregroundStyle(.secondary)
                    Text(node.formattedSize)
                        .fontWeight(.medium)
                }
                
                Divider()
                
                HStack(spacing: 4) {
                    Text("Items:")
                        .foregroundStyle(.secondary)
                    Text("\(node.children.count)")
                        .fontWeight(.medium)
                }
                
                if viewModel.scanDuration > 0 {
                    Divider()
                    
                    HStack(spacing: 4) {
                        Text("Scan time:")
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2fs", viewModel.scanDuration))
                            .fontWeight(.medium)
                    }
                }
            }
            
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }
}
