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
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showFilePicker = false
    @State private var quickLookURL: URL?

    private enum ExportFormat {
        case json
        case csv
    }

    private func showSavePanel(format: ExportFormat) {
        let savePanel = NSSavePanel()
        switch format {
        case .json:
            savePanel.allowedContentTypes = [.json]
            savePanel.nameFieldStringValue = "DiskInventoryScan.json"
        case .csv:
            savePanel.allowedContentTypes = [.commaSeparatedText]
            savePanel.nameFieldStringValue = "DiskInventoryScan.csv"
        }
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                switch format {
                case .json:
                    viewModel.exportScanData(to: url)
                case .csv:
                    viewModel.exportCSV(to: url)
                }
            }
        }
    }

    private func showSnapshotComparisonPanel() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.message = "Choose a Disk Inventory Zed JSON snapshot from an earlier scan."
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                viewModel.compareWithSnapshot(at: url)
            }
        }
    }
    
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
                        Group {
                            if viewModel.viewMode == .treemap {
                                TreemapView(node: node)
                            } else if viewModel.viewMode == .sunburst {
                                SunburstChartView(node: node)
                            } else {
                                FileListView(node: node)
                            }
                        }
                        .animation(.easeInOut(duration: 0.25), value: viewModel.currentNode)
                        .overlay(alignment: .bottomLeading) {
                            StatusBarView()
                        }
                    } else {
                        EmptyStateView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                if viewModel.rootNode != nil && !viewModel.isScanning {
                    Divider()
                    RightSidebarView()
                        .frame(width: 360)
                        .background(.ultraThinMaterial)
                }
            }
        }
        .searchable(text: $viewModel.searchQuery, prompt: "Search files...")
        .quickLookPreview($quickLookURL)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if viewModel.rootNode != nil && !viewModel.isScanning {
                        Menu {
                            Button("Export Snapshot (JSON)…") {
                                showSavePanel(format: .json)
                            }
                            Button("Export CSV…") {
                                showSavePanel(format: .csv)
                            }

                            Divider()

                            Button("Compare with Snapshot…") {
                                showSnapshotComparisonPanel()
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .help("Export scan data or compare it with an earlier snapshot")

                        Button {
                            viewModel.rescan()
                        } label: {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                        .help("Scan this location again")
                    }
                    
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
                Button(action: { viewModel.navigateBack() }) {
                    Label("Back", systemImage: "arrow.left")
                }
                .disabled(!viewModel.canNavigateBack)
                .help("Go back (⌘[)")
                
                Button(action: { viewModel.navigateForward() }) {
                    Label("Forward", systemImage: "arrow.right")
                }
                .disabled(!viewModel.canNavigateForward)
                .help("Go forward (⌘])")
                
                Divider()
                
                Button(action: { viewModel.navigateUp() }) {
                    Label("Up", systemImage: "arrow.up")
                }
                .disabled(viewModel.breadcrumb.count <= 1)
                .help("Go to parent folder (⌘↑)")
                
                Button(action: { viewModel.navigateToRoot() }) {
                    Label("Root", systemImage: "arrow.up.to.line")
                }
                .disabled(viewModel.currentNode == viewModel.rootNode)
                .help("Go to root folder")
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
        .alert(
            "Move Item to Trash?",
            isPresented: Binding(
                get: { viewModel.pendingTrashNode != nil },
                set: { isPresented in
                    if !isPresented { viewModel.cancelMoveToTrash() }
                }
            ),
            presenting: viewModel.pendingTrashNode
        ) { _ in
            Button("Move to Trash", role: .destructive) {
                viewModel.confirmMoveToTrash()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelMoveToTrash()
            }
        } message: { node in
            Text("“\(node.displayName)” uses \(node.formattedSize) on disk. This moves it to the macOS Trash; it is not permanently erased.")
        }
    }
}

struct ToolbarView: View {
    @EnvironmentObject var viewModel: AppViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
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
            }
            .frame(minWidth: 120)
            
            Spacer()

            if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Picker("Search Scope", selection: $viewModel.searchScope) {
                    ForEach(AppViewModel.SearchScope.allCases, id: \.self) { scope in
                        Text(scope.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 125)
            }
            
            Picker("View", selection: $viewModel.viewMode) {
                ForEach(AppViewModel.ViewMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.icon)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            
            Picker("Min Size", selection: $viewModel.sizeThreshold) {
                Text("All Sizes").tag(Int64(0))
                Text("> 1 MB").tag(Int64(1_000_000))
                Text("> 10 MB").tag(Int64(10_000_000))
                Text("> 100 MB").tag(Int64(100_000_000))
                Text("> 1 GB").tag(Int64(1_000_000_000))
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            
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

                if !viewModel.scanStatusPath.isEmpty {
                    Text(viewModel.scanStatusPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 520)
                }
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

            if let lastPath = UserSettings.lastScanPath,
               FileManager.default.fileExists(atPath: lastPath) {
                Button {
                    viewModel.restoreLastScan()
                } label: {
                    Label("Rescan Last Location", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
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
    @State private var isExpanded = false
    
    var body: some View {
        HStack(spacing: 8) {
            if let node = viewModel.currentNode {
                HStack(spacing: 4) {
                    Text(node.formattedSize)
                        .font(.system(size: 10, weight: .medium))
                    
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    
                    Text("\(node.children.count) items")
                        .font(.system(size: 10))
                }
                
                if viewModel.scanDuration > 0 && isExpanded {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    
                    Text(String(format: "%.2fs", viewModel.scanDuration))
                        .font(.system(size: 10))
                }

                if viewModel.scanDiagnostics.unreadableItems > 0 && isExpanded {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Label(
                        "\(viewModel.scanDiagnostics.unreadableItems) unreadable",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                }
            }
            
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial)
        .cornerRadius(4)
        .shadow(radius: 1)
        .padding(8)
    }
}
