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

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
                .padding(.top, 24)
            
            Text("Disk Inventory Zed")
                .font(.system(size: 20, weight: .bold))
            
            Text("Version 1.0")
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
                Picker("View Mode", selection: $viewModel.viewMode) {
                    ForEach(AppViewModel.ViewMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode.icon)
                    }
                }
                .pickerStyle(.inline)
                
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
                .disabled(viewModel.currentNode?.parent == nil)
                
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
        }
        .defaultSize(width: 1200, height: 800)
    }
}
