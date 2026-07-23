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
    @State private var lastHoverPosition: CGPoint = .zero
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                let rects = calculateTreemap(
                    node: node,
                    rect: CGRect(origin: .zero, size: geometry.size)
                )
                
                let clickedRect = rects.last(where: { $0.rect.contains(lastHoverPosition) })
                
                Canvas { context, size in
                    for treemapRect in rects {
                        let path = Path(treemapRect.rect)
                        
                        // Determine opacity based on selection or search query
                        var opacity: Double = 1.0
                        if let selectedExt = viewModel.selectedExtension {
                            let ext = treemapRect.node.extension?.lowercased() ?? ""
                            if treemapRect.node.isDirectory {
                                opacity = 0.45
                            } else if ext != selectedExt.lowercased() {
                                opacity = 0.12
                            }
                        } else if !viewModel.searchQuery.isEmpty {
                            let matches = treemapRect.node.displayName.localizedCaseInsensitiveContains(viewModel.searchQuery) ||
                                treemapRect.node.path.localizedCaseInsensitiveContains(viewModel.searchQuery)
                            if treemapRect.node.isDirectory {
                                opacity = 0.45
                            } else if !matches {
                                opacity = 0.12
                            }
                        }
                        
                        var localContext = context
                        localContext.opacity = opacity
                        localContext.fill(
                            path,
                            with: .color(
                                treemapRect.node.isDirectory
                                    ? treemapRect.color.opacity(0.72)
                                    : treemapRect.color
                            )
                        )
                        
                        let strokePath = Path(treemapRect.rect.insetBy(dx: 0.5, dy: 0.5))
                        localContext.stroke(
                            strokePath,
                            with: .color(.white.opacity(treemapRect.node.isDirectory ? 0.55 : 0.25)),
                            lineWidth: treemapRect.node.isDirectory ? 1.25 : 0.5
                        )
                        
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
                    if let rect = rects.last(where: { $0.rect.contains(location) }) {
                        viewModel.navigateTo(node: rect.node)
                    }
                }
                .onDrag {
                    if let hovered = hoveredRect {
                        return NSItemProvider(object: hovered.node.url as NSURL)
                    }
                    return NSItemProvider()
                }
                .overlay(
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    lastHoverPosition = location
                                    if let rect = rects.last(where: { $0.rect.contains(location) }) {
                                        hoveredRect = rect
                                        tooltipPosition = location
                                    } else {
                                        hoveredRect = nil
                                    }
                                case .ended:
                                    hoveredRect = nil
                                }
                            }
                            .contextMenu {
                                let target = clickedRect
                                if let hovered = target {
                                    Text(hovered.node.displayName)
                                        .font(.headline)
                                    
                                    Divider()
                                    
                                    Button("Open") {
                                        viewModel.openFile(node: hovered.node)
                                    }
                                    
                                    Button("Reveal in Finder") {
                                        viewModel.revealInFinder(node: hovered.node)
                                    }
                                    
                                    Button("Open Containing Folder") {
                                        viewModel.openContainingFolder(node: hovered.node)
                                    }
                                    
                                    Button("Move to Trash") {
                                        viewModel.moveToTrash(node: hovered.node)
                                    }
                                } else {
                                    Text("No item under mouse pointer")
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
        guard rect.width > 1, rect.height > 1 else { return [] }

        let maximumRectangles = 60_000
        let minimumExpandableArea: CGFloat = 120
        let maximumDepth = 64
        var result: [TreemapRect] = []
        result.reserveCapacity(min(4_096, maximumRectangles))

        func appendChildren(of parent: FileNode, in parentRect: CGRect, depth: Int) {
            guard depth < maximumDepth,
                  result.count < maximumRectangles else {
                return
            }

            let children = parent.children.filter {
                $0.size > 0 &&
                (viewModel.sizeThreshold == 0 || $0.size >= viewModel.sizeThreshold)
            }
            guard !children.isEmpty else {
                return
            }
            guard children.count <= maximumRectangles - result.count else {
                if result.isEmpty {
                    result.append(TreemapRect(
                        node: parent,
                        rect: parentRect,
                        color: FileTypeColors.color(for: parent),
                        depth: depth
                    ))
                }
                return
            }

            for layout in squarify(children: children, in: parentRect) {
                guard layout.rect.width >= 0.5,
                      layout.rect.height >= 0.5 else {
                    continue
                }

                result.append(TreemapRect(
                    node: layout.node,
                    rect: layout.rect,
                    color: FileTypeColors.color(for: layout.node),
                    depth: depth
                ))

                guard layout.node.isDirectory,
                      !layout.node.children.isEmpty,
                      layout.rect.width * layout.rect.height >= minimumExpandableArea,
                      result.count < maximumRectangles else {
                    continue
                }

                let inset: CGFloat = min(4, max(1.5, min(layout.rect.width, layout.rect.height) * 0.025))
                var childRect = layout.rect.insetBy(dx: inset, dy: inset)
                if layout.rect.height > 26 {
                    childRect.origin.y += 12
                    childRect.size.height -= 12
                }
                guard childRect.width > 2, childRect.height > 2 else { continue }
                appendChildren(of: layout.node, in: childRect, depth: depth + 1)
            }
        }

        appendChildren(of: node, in: rect, depth: 0)
        return result
    }

    private func squarify(children: [FileNode], in rect: CGRect) -> [NodeLayout] {
        let sorted = children.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let totalSize = sorted.reduce(Int64(0)) { $0 + $1.size }
        guard totalSize > 0, rect.width > 0, rect.height > 0 else { return [] }

        let scale = (rect.width * rect.height) / CGFloat(totalSize)
        let items = sorted.map { WeightedNode(node: $0, area: CGFloat($0.size) * scale) }
        var itemIndex = 0
        var remainingRect = rect
        var layouts: [NodeLayout] = []

        while itemIndex < items.count && remainingRect.width > 0 && remainingRect.height > 0 {
            var row: [WeightedNode] = []
            let shortSide = min(remainingRect.width, remainingRect.height)
            var rowMetrics = SquarifyRowMetrics()

            while itemIndex < items.count {
                let next = items[itemIndex]
                let candidateMetrics = rowMetrics.adding(next.area)
                if row.isEmpty ||
                   candidateMetrics.worstRatio(shortSide: shortSide) <=
                    rowMetrics.worstRatio(shortSide: shortSide) {
                    row.append(next)
                    rowMetrics = candidateMetrics
                    itemIndex += 1
                } else {
                    break
                }
            }

            let laidOut = layout(row: row, in: remainingRect)
            layouts.append(contentsOf: laidOut.layouts)
            remainingRect = laidOut.remainder
        }

        return layouts
    }

    private func layout(row: [WeightedNode], in rect: CGRect) -> (layouts: [NodeLayout], remainder: CGRect) {
        guard !row.isEmpty else { return ([], rect) }
        let rowArea = row.reduce(CGFloat(0)) { $0 + $1.area }
        var layouts: [NodeLayout] = []

        if rect.width >= rect.height {
            let columnWidth = min(rect.width, rowArea / rect.height)
            guard columnWidth > 0 else { return ([], rect) }
            var y = rect.minY
            for (index, item) in row.enumerated() {
                let height = index == row.count - 1
                    ? max(0, rect.maxY - y)
                    : item.area / columnWidth
                layouts.append(NodeLayout(
                    node: item.node,
                    rect: CGRect(x: rect.minX, y: y, width: columnWidth, height: height)
                ))
                y += height
            }
            return (
                layouts,
                CGRect(
                    x: rect.minX + columnWidth,
                    y: rect.minY,
                    width: max(0, rect.width - columnWidth),
                    height: rect.height
                )
            )
        }

        let rowHeight = min(rect.height, rowArea / rect.width)
        guard rowHeight > 0 else { return ([], rect) }
        var x = rect.minX
        for (index, item) in row.enumerated() {
            let width = index == row.count - 1
                ? max(0, rect.maxX - x)
                : item.area / rowHeight
            layouts.append(NodeLayout(
                node: item.node,
                rect: CGRect(x: x, y: rect.minY, width: width, height: rowHeight)
            ))
            x += width
        }
        return (
            layouts,
            CGRect(
                x: rect.minX,
                y: rect.minY + rowHeight,
                width: rect.width,
                height: max(0, rect.height - rowHeight)
            )
        )
    }
}

struct TreemapRect: Identifiable {
    let id = UUID()
    let node: FileNode
    let rect: CGRect
    let color: Color
    let depth: Int
}

private struct WeightedNode {
    let node: FileNode
    let area: CGFloat
}

private struct SquarifyRowMetrics {
    var sum: CGFloat = 0
    var minimum: CGFloat = .infinity
    var maximum: CGFloat = 0

    func adding(_ area: CGFloat) -> SquarifyRowMetrics {
        SquarifyRowMetrics(
            sum: sum + area,
            minimum: min(minimum, area),
            maximum: max(maximum, area)
        )
    }

    func worstRatio(shortSide: CGFloat) -> CGFloat {
        guard sum > 0, minimum > 0, shortSide > 0 else { return .infinity }
        let sideSquared = shortSide * shortSide
        let sumSquared = sum * sum
        return max(
            sideSquared * maximum / sumSquared,
            sumSquared / (sideSquared * minimum)
        )
    }
}

private struct NodeLayout {
    let node: FileNode
    let rect: CGRect
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
