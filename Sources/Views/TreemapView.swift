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
//
// Design inspiration: Disk Inventory X by Tjark Derlien, KDirStat by Alexander Lehmann

import SwiftUI

struct TreemapView: View {
    let node: FileNode
    @EnvironmentObject var viewModel: AppViewModel
    @State private var hoveredRect: TreemapRect?
    @State private var tooltipPosition: CGPoint = .zero
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                let rects = calculateTreemap(
                    node: node,
                    rect: CGRect(origin: .zero, size: geometry.size)
                )
                
                Canvas { context, size in
                    for treemapRect in rects {
                        let path = Path(treemapRect.rect)
                        
                        // Determine opacity based on selection or search query
                        var opacity: Double = 1.0
                        if let selectedExt = viewModel.selectedExtension {
                            let ext = treemapRect.node.extension?.lowercased() ?? ""
                            if ext != selectedExt.lowercased() {
                                opacity = 0.15
                            }
                        } else if !viewModel.searchQuery.isEmpty {
                            if !treemapRect.node.displayName.localizedCaseInsensitiveContains(viewModel.searchQuery) {
                                opacity = 0.15
                            }
                        }
                        
                        var localContext = context
                        localContext.opacity = opacity
                        localContext.fill(path, with: .color(treemapRect.color))
                        
                        let strokePath = Path(treemapRect.rect.insetBy(dx: 0.5, dy: 0.5))
                        localContext.stroke(strokePath, with: .color(.white.opacity(0.3)), lineWidth: 1)
                        
                        // If the rect is large enough, draw the name of the file/folder
                        if treemapRect.rect.width > 70 && treemapRect.rect.height > 25 {
                            let text = Text(treemapRect.node.displayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white)
                            localContext.draw(text, at: CGPoint(x: treemapRect.rect.midX, y: treemapRect.rect.midY), anchor: .center)
                        }
                    }
                }
                .onTapGesture { location in
                    if let rect = rects.first(where: { $0.rect.contains(location) }) {
                        viewModel.navigateTo(node: rect.node)
                    }
                }
                .onDrag {
                    if let hovered = hoveredRect {
                        return NSItemProvider(object: hovered.node.url as NSURL)
                    }
                    return NSItemProvider()
                }
                .contextMenu {
                    if let hovered = hoveredRect {
                        Text(hovered.node.displayName)
                            .font(.headline)
                        
                        Divider()
                        
                        Button("Open") {
                            viewModel.openFile(node: hovered.node)
                        }
                        
                        Button("Reveal in Finder") {
                            viewModel.revealInFinder(node: hovered.node)
                        }
                        
                        if !hovered.node.isDirectory {
                            Button("Move to Trash") {
                                viewModel.moveToTrash(node: hovered.node)
                            }
                        }
                    } else {
                        Text("No item under mouse pointer")
                    }
                }
                .onHover { isHovering in
                    if !isHovering {
                        hoveredRect = nil
                    }
                }
                .overlay(
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    if let rect = rects.first(where: { $0.rect.contains(location) }) {
                                        hoveredRect = rect
                                        tooltipPosition = location
                                    } else {
                                        hoveredRect = nil
                                    }
                                case .ended:
                                    hoveredRect = nil
                                }
                            }
                    }
                )
                
                if let hovered = hoveredRect {
                    TreemapTooltip(rect: hovered)
                        .position(x: tooltipPosition.x + 10, y: tooltipPosition.y - 10)
                }
            }
        }
        .background(Color.black.opacity(0.05))
    }
    
    private func calculateTreemap(node: FileNode, rect: CGRect) -> [TreemapRect] {
        let children = viewModel.filteredChildren
        guard !children.isEmpty else { return [] }
        
        let totalSize = children.reduce(0) { $0 + $1.size }
        guard totalSize > 0 else { return [] }
        
        var rects: [TreemapRect] = []
        var remaining = rect
        var remainingChildren = children
        var remainingSize = totalSize
        
        while !remainingChildren.isEmpty && remainingSize > 0 {
            let row = buildRow(
                children: remainingChildren,
                remainingSize: remainingSize,
                rect: remaining
            )
            
            let rowSize = row.reduce(0) { $0 + $1.size }
            let rowRects = layoutRow(
                row: row,
                rowSize: rowSize,
                totalSize: remainingSize,
                rect: remaining
            )
            
            rects.append(contentsOf: rowRects)
            
            remainingChildren.removeFirst(row.count)
            remainingSize -= rowSize
            
            if rowRects.first?.rect.width ?? 0 > rowRects.first?.rect.height ?? 0 {
                let usedHeight = rowRects.map { $0.rect.height }.max() ?? 0
                remaining.origin.y += usedHeight
                remaining.size.height -= usedHeight
            } else {
                let usedWidth = rowRects.map { $0.rect.width }.max() ?? 0
                remaining.origin.x += usedWidth
                remaining.size.width -= usedWidth
            }
        }
        
        return rects
    }
    
    private func buildRow(children: [FileNode], remainingSize: Int64, rect: CGRect) -> [FileNode] {
        guard !children.isEmpty else { return [] }
        
        var row: [FileNode] = [children[0]]
        var rowSize = children[0].size
        
        let shortSide = min(rect.width, rect.height)
        
        for i in 1..<children.count {
            let newRow = row + [children[i]]
            let newRowSize = rowSize + children[i].size
            
            let currentRatio = worstRatio(row: row, rowSize: rowSize, shortSide: shortSide)
            let newRatio = worstRatio(row: newRow, rowSize: newRowSize, shortSide: shortSide)
            
            if newRatio <= currentRatio {
                row = newRow
                rowSize = newRowSize
            } else {
                break
            }
        }
        
        return row
    }
    
    private func worstRatio(row: [FileNode], rowSize: Int64, shortSide: CGFloat) -> CGFloat {
        guard rowSize > 0 && shortSide > 0 else { return .infinity }
        
        let rowArea = CGFloat(rowSize)
        let sideSquared = shortSide * shortSide
        let rowSquared = rowArea * rowArea
        
        var maxRatio: CGFloat = 0
        
        for node in row {
            let nodeArea = CGFloat(node.size)
            let ratio = max(
                sideSquared * nodeArea / rowSquared,
                rowSquared / (sideSquared * nodeArea)
            )
            maxRatio = max(maxRatio, ratio)
        }
        
        return maxRatio
    }
    
    private func layoutRow(row: [FileNode], rowSize: Int64, totalSize: Int64, rect: CGRect) -> [TreemapRect] {
        guard rowSize > 0 && totalSize > 0 else { return [] }
        
        let isHorizontal = rect.width > rect.height
        let rowLength = isHorizontal ? rect.width : rect.height
        let rowDepth = isHorizontal ? rect.height : rect.width
        
        let scale = CGFloat(rowSize) / CGFloat(totalSize)
        let actualRowDepth = rowDepth * scale
        
        var currentPos: CGFloat = 0
        var rects: [TreemapRect] = []
        
        for node in row {
            let nodeScale = CGFloat(node.size) / CGFloat(rowSize)
            let nodeLength = rowLength * nodeScale
            
            let nodeRect: CGRect
            if isHorizontal {
                nodeRect = CGRect(
                    x: rect.origin.x + currentPos,
                    y: rect.origin.y,
                    width: nodeLength,
                    height: actualRowDepth
                )
            } else {
                nodeRect = CGRect(
                    x: rect.origin.x,
                    y: rect.origin.y + currentPos,
                    width: actualRowDepth,
                    height: nodeLength
                )
            }
            
            rects.append(TreemapRect(
                node: node,
                rect: nodeRect,
                color: FileTypeColors.color(for: node)
            ))
            
            currentPos += nodeLength
        }
        
        return rects
    }
}

struct TreemapRect: Identifiable {
    let id = UUID()
    let node: FileNode
    let rect: CGRect
    let color: Color
}

struct TreemapTooltip: View {
    let rect: TreemapRect
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rect.node.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            
            Text(rect.node.formattedSize)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            
            if rect.node.isDirectory {
                Text("\(rect.node.children.count) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(6)
        .shadow(radius: 4)
        .frame(maxWidth: 200)
    }
}
