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
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Disk Inventory Zed") {
                    let credits: NSMutableAttributedString = {
                        let str = NSMutableAttributedString(
                            string: "Made by Matt Ivan\nmattivan.com\n\nInspired by Disk Inventory X & KDirStat"
                        )
                        str.addAttributes([
                            .font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ], range: NSRange(location: 0, length: str.length))
                        
                        let linkRange = (str.string as NSString).range(of: "mattivan.com")
                        if linkRange.location != NSNotFound {
                            str.addAttribute(.link, value: "https://mattivan.com", range: linkRange)
                        }
                        return str
                    }()
                    
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "Disk Inventory Zed",
                            .applicationVersion: "1.0",
                            .credits: credits
                        ]
                    )
                }
            }
        }
    }
}
