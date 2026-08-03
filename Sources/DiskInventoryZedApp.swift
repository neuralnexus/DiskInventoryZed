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
//
// Design inspiration: Disk Inventory X by Tjark Derlien, KDirStat by Alexander Lehmann

import SwiftUI

@MainActor
func showAboutWindow() {
    let aboutWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    aboutWindow.title = "About Disk Inventory Zed"
    aboutWindow.center()
    
    let aboutView = AboutView()
    aboutWindow.contentView = NSHostingView(rootView: aboutView)
    aboutWindow.makeKeyAndOrderFront(nil)
}

@MainActor
func showHelpWindow() {
    let helpWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    helpWindow.title = "Disk Inventory Zed Help"
    helpWindow.center()
    
    let helpView = HelpView()
    helpWindow.contentView = NSHostingView(rootView: helpView)
    helpWindow.makeKeyAndOrderFront(nil)
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
                .padding(.top, 24)
            
            Text("Disk Inventory Zed")
                .font(.system(size: 20, weight: .bold))
            
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            
            Divider()
                .padding(.horizontal, 40)
            
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("Made by ")
                        .font(.system(size: 13))
                    
                    Link("Matt Ivan", destination: URL(string: "https://mattivan.com?ref=diskinventoryzed")!)
                        .font(.system(size: 13, weight: .semibold))
                }
                
                Text("Inspired by Disk Inventory X & KDirStat")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Text("GPL-3.0 License")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .frame(width: 420, height: 320)
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "externaldrive.badge.checkmark")
                            .font(.system(size: 48))
                            .foregroundColor(.accentColor)
                        
                        Text("Disk Inventory Zed")
                            .font(.system(size: 18, weight: .bold))
                        
                        Text("Quick Reference Guide")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.top, 16)
                
                Divider()
                
                // Keyboard Shortcuts
                HelpSection(title: "Keyboard Shortcuts", icon: "keyboard") {
                    VStack(alignment: .leading, spacing: 8) {
                        HelpShortcut(key: "⌘ [", description: "Navigate back")
                        HelpShortcut(key: "⌘ ]", description: "Navigate forward")
                        HelpShortcut(key: "⌘ ↑", description: "Navigate up to parent folder")
                        HelpShortcut(key: "⌘ O", description: "Open selected file/folder")
                        HelpShortcut(key: "⌘ R", description: "Reveal in Finder")
                        HelpShortcut(key: "⌘ Delete", description: "Move to trash")
                        HelpShortcut(key: "⌘ 1", description: "Treemap view")
                        HelpShortcut(key: "⌘ 2", description: "List view")
                        HelpShortcut(key: "⌘ 3", description: "Sunburst view")
                        HelpShortcut(key: "⌘ ?", description: "Show this help")
                    }
                }
                
                // Views
                HelpSection(title: "View Modes", icon: "eye") {
                    VStack(alignment: .leading, spacing: 8) {
                        HelpItem(title: "Treemap", description: "Rectangular visualization where each file/folder is a rectangle sized proportionally to its disk usage. Click to drill down, right-click for options.")
                        HelpItem(title: "Sunburst", description: "Radial chart with concentric rings. Each ring represents a folder level. Click a slice to drill in, right-click for options.")
                        HelpItem(title: "List", description: "Traditional file browser view with sortable columns. Click to navigate, right-click for options.")
                    }
                }
                
                // Navigation
                HelpSection(title: "Navigation", icon: "arrow.left.arrow.right") {
                    VStack(alignment: .leading, spacing: 8) {
                        HelpItem(title: "Breadcrumb", description: "Click any folder in the path bar at the top to jump directly to that folder.")
                        HelpItem(title: "Back/Forward", description: "Use the toolbar buttons or ⌘[ / ⌘] to navigate through your browsing history.")
                        HelpItem(title: "Drill In", description: "Click any folder in the treemap, sunburst, or list to focus on that folder.")
                        HelpItem(title: "Sidebar", description: "The left sidebar shows the folder tree. Click to navigate, right-click for options.")
                    }
                }
                
                // File Operations
                HelpSection(title: "File Operations", icon: "doc") {
                    VStack(alignment: .leading, spacing: 8) {
                        HelpItem(title: "Open", description: "Opens the file with its default application.")
                        HelpItem(title: "Reveal in Finder", description: "Opens Finder and selects the file.")
                        HelpItem(title: "Open Containing Folder", description: "Opens the parent folder in Finder.")
                        HelpItem(title: "Move to Trash", description: "Moves the selected file to trash and refreshes the view.")
                        HelpItem(title: "Quick Look", description: "Select an item and use the Preview button in the toolbar.")
                        HelpItem(title: "Drag and Drop", description: "Drag files from the treemap, sunburst, or list directly to Finder or other apps.")
                    }
                }
                
                // Scan Options
                HelpSection(title: "Scan Options", icon: "slider.horizontal.3") {
                    VStack(alignment: .leading, spacing: 8) {
                        HelpItem(title: "Skip Dev Folders", description: "Skip node_modules, .git, .svn, and DerivedData folders to make scans faster.")
                        HelpItem(title: "Show Hidden Files", description: "Include hidden files (starting with .) in the scan results.")
                        HelpItem(title: "Show Package Contents", description: "When on, .app bundles and packages are treated as folders. When off, they're single files.")
                        HelpItem(title: "Follow Symlinks", description: "Follow symbolic links to their targets. Default is off to prevent infinite loops.")
                    }
                }
                
                // Filters
                HelpSection(title: "Filters & Search", icon: "magnifyingglass") {
                    VStack(alignment: .leading, spacing: 8) {
                        HelpItem(title: "Search", description: "Use the search bar to find files by name across the entire scanned tree.")
                        HelpItem(title: "Size Filter", description: "Show only files larger than 1MB, 10MB, 100MB, or 1GB.")
                        HelpItem(title: "File Type Filter", description: "Click a file type in the right sidebar to highlight only files of that type.")
                        HelpItem(title: "Sort", description: "Sort by size (largest first), size (smallest first), or name (A-Z or Z-A).")
                    }
                }
                
                // Export
                HelpSection(title: "Export", icon: "square.and.arrow.up") {
                    VStack(alignment: .leading, spacing: 8) {
                        HelpItem(title: "Snapshot JSON", description: "Save a reconstructable, versioned snapshot with allocated and logical sizes plus scan diagnostics.")
                        HelpItem(title: "Compare Snapshots", description: "Scan the same location later and compare it with an earlier snapshot to find growth, removals, and resized files.")
                        HelpItem(title: "CSV", description: "Export a streaming flat-file inventory for analysis in spreadsheets, databases, or scripts.")
                    }
                }
                
                // Tips
                HelpSection(title: "Tips", icon: "lightbulb") {
                    VStack(alignment: .leading, spacing: 8) {
                        HelpItem(title: "Large Files", description: "Use size filters to quickly find the biggest files taking up space.")
                        HelpItem(title: "Dev Folders", description: "If scanning a code project, enable 'Skip Dev Folders' to ignore node_modules and .git.")
                        HelpItem(title: "Hover", description: "Hover over any item in treemap or sunburst to see a tooltip with details.")
                        HelpItem(title: "History", description: "The back/forward buttons track your navigation history, so you can easily return to previous folders.")
                    }
                }
                
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

struct HelpSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                
                Text(title)
                    .font(.system(size: 16, weight: .bold))
            }
            
            content
                .padding(.leading, 24)
        }
    }
}

struct HelpItem: View {
    let title: String
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HelpShortcut: View {
    let key: String
    let description: String
    
    var body: some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)
                .frame(minWidth: 80, alignment: .leading)
            
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            
            Spacer()
        }
    }
}

@main
struct DiskInventoryZedApp: App {
    @StateObject private var viewModel = AppViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandMenu("View") {
                Button("Treemap") {
                    viewModel.viewMode = .treemap
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("List") {
                    viewModel.viewMode = .list
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Sunburst") {
                    viewModel.viewMode = .sunburst
                }
                .keyboardShortcut("3", modifiers: .command)
                
                Divider()
                
                Picker("Sort By", selection: $viewModel.sortOrder) {
                    ForEach(AppViewModel.SortOrder.allCases, id: \.self) { order in
                        Label(order.rawValue, systemImage: order.icon)
                    }
                }
                .pickerStyle(.inline)
            }
            
            CommandGroup(replacing: .textEditing) {
                Button("Navigate Back") {
                    viewModel.navigateBack()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!viewModel.canNavigateBack)
                
                Button("Navigate Forward") {
                    viewModel.navigateForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!viewModel.canNavigateForward)
                
                Button("Navigate Up") {
                    viewModel.navigateUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(viewModel.breadcrumb.count <= 1)
                
                Divider()
                
                Button("Open") {
                    if let selected = viewModel.selectedNode {
                        viewModel.openFile(node: selected)
                    } else if let current = viewModel.currentNode {
                        viewModel.openFile(node: current)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Button("Reveal in Finder") {
                    if let selected = viewModel.selectedNode {
                        viewModel.revealInFinder(node: selected)
                    } else if let current = viewModel.currentNode {
                        viewModel.revealInFinder(node: current)
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                
                Button("Move to Trash") {
                    if let selected = viewModel.selectedNode {
                        viewModel.moveToTrash(node: selected)
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            
            CommandGroup(replacing: .appInfo) {
                Button("About Disk Inventory Zed") {
                    showAboutWindow()
                }
            }
            
            CommandGroup(replacing: .help) {
                Button("Disk Inventory Zed Help") {
                    showHelpWindow()
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
        .defaultSize(width: 1200, height: 800)
    }
}
