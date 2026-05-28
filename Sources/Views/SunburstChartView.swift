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

struct SunburstChartView: View {
    let node: FileNode
    @EnvironmentObject var viewModel: AppViewModel
    @State private var hoveredSlice: SunburstSlice?
    @State private var tooltipPosition: CGPoint = .zero
    
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let slices = calculateSlices(node: node, center: center)
            
            ZStack {
                Canvas { context, size in
                    // Draw center circle (representing the currentNode itself)
                    let centerPath = Path(ellipseIn: CGRect(
                        x: center.x - 40,
                        y: center.y - 40,
                        width: 80,
                        height: 80
                    ))
                    context.fill(centerPath, with: .color(.secondary.opacity(0.15)))
                    
                    let centerText = Text(node.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.primary)
                    context.draw(centerText, at: center, anchor: .center)
                    
                    // Draw slices
                    for slice in slices {
                        let path = buildArcPath(center: center, slice: slice)
                        
                        // Set opacity based on highlighting or search query
                        var opacity: Double = 1.0
                        if let selectedExt = viewModel.selectedExtension {
                            let ext = slice.node.extension?.lowercased() ?? ""
                            if ext != selectedExt.lowercased() {
                                opacity = 0.15
                            }
                        } else if !viewModel.searchQuery.isEmpty {
                            if !slice.node.displayName.localizedCaseInsensitiveContains(viewModel.searchQuery) {
                                opacity = 0.15
                            }
                        }
                        
                        var localContext = context
                        localContext.opacity = opacity
                        localContext.fill(path, with: .color(slice.color))
                        
                        // Draw thin border for distinct slices
                        let strokePath = buildArcPath(center: center, slice: slice)
                        localContext.stroke(strokePath, with: .color(.black.opacity(0.15)), lineWidth: 0.5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if let clicked = hitTest(location: location, center: center, slices: slices) {
                        viewModel.navigateTo(node: clicked.node)
                    }
                }
                .onHover { isHovering in
                    if !isHovering {
                        hoveredSlice = nil
                    }
                }
                .overlay(
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                if let hit = hitTest(location: location, center: center, slices: slices) {
                                    hoveredSlice = hit
                                    tooltipPosition = location
                                } else {
                                    hoveredSlice = nil
                                }
                            case .ended:
                                hoveredSlice = nil
                            }
                        }
                )
                
                if let hovered = hoveredSlice {
                    SunburstTooltip(slice: hovered)
                        .position(x: tooltipPosition.x + 10, y: tooltipPosition.y - 15)
                }
            }
        }
        .background(Color.black.opacity(0.02))
    }
    
    // MARK: - Slices calculation
    
    private func calculateSlices(node: FileNode, center: CGPoint) -> [SunburstSlice] {
        var slices: [SunburstSlice] = []
        
        let maxDepth = 3
        let ringWidth = 50.0
        let baseRadius = 45.0
        
        func processNodeChildren(parent: FileNode, depth: Int, startAngle: Double, endAngle: Double) {
            guard depth < maxDepth else { return }
            
            // Only fetch filtered children matching search query or min size threshold
            let children = parent.children.filter { child in
                if viewModel.sizeThreshold > 0 && child.size < viewModel.sizeThreshold {
                    return false
                }
                return true
            }
            
            guard !children.isEmpty else { return }
            let parentSize = children.reduce(0) { $0 + $1.size }
            guard parentSize > 0 else { return }
            
            var currentAngle = startAngle
            let totalSpan = endAngle - startAngle
            
            let innerRadius = baseRadius + Double(depth) * ringWidth
            let outerRadius = innerRadius + ringWidth - 4.0
            
            for child in children {
                let proportion = Double(child.size) / Double(parentSize)
                let span = proportion * totalSpan
                let nextAngle = currentAngle + span
                
                // Only draw visible slices (> 0.5 degrees)
                if span > 0.5 {
                    let slice = SunburstSlice(
                        node: child,
                        startAngle: currentAngle,
                        endAngle: nextAngle,
                        innerRadius: innerRadius,
                        outerRadius: outerRadius,
                        color: FileTypeColors.color(for: child)
                    )
                    slices.append(slice)
                    
                    // Recurse into directory children
                    if child.isDirectory {
                        processNodeChildren(parent: child, depth: depth + 1, startAngle: currentAngle, endAngle: nextAngle)
                    }
                }
                currentAngle = nextAngle
            }
        }
        
        processNodeChildren(parent: node, depth: 0, startAngle: 0.0, endAngle: 360.0)
        return slices
    }
    
    private func buildArcPath(center: CGPoint, slice: SunburstSlice) -> Path {
        var path = Path()
        
        // Convert angles to radians for standard trigonometry
        let startRad = slice.startAngle * .pi / 180.0
        let endRad = slice.endAngle * .pi / 180.0
        
        // Outer arc start
        let outerStartX = center.x + CGFloat(cos(startRad) * slice.outerRadius)
        let outerStartY = center.y + CGFloat(sin(startRad) * slice.outerRadius)
        
        path.move(to: CGPoint(x: outerStartX, y: outerStartY))
        
        // Outer arc
        path.addArc(
            center: center,
            radius: CGFloat(slice.outerRadius),
            startAngle: Angle(degrees: slice.startAngle),
            endAngle: Angle(degrees: slice.endAngle),
            clockwise: false
        )
        
        // Inner arc start
        let innerEndX = center.x + CGFloat(cos(endRad) * slice.innerRadius)
        let innerEndY = center.y + CGFloat(sin(endRad) * slice.innerRadius)
        
        path.addLine(to: CGPoint(x: innerEndX, y: innerEndY))
        
        // Inner arc
        path.addArc(
            center: center,
            radius: CGFloat(slice.innerRadius),
            startAngle: Angle(degrees: slice.endAngle),
            endAngle: Angle(degrees: slice.startAngle),
            clockwise: true
        )
        
        path.closeSubpath()
        return path
    }
    
    // MARK: - Hit testing
    
    private func hitTest(location: CGPoint, center: CGPoint, slices: [SunburstSlice]) -> SunburstSlice? {
        let dx = Double(location.x - center.x)
        let dy = Double(location.y - center.y)
        let distance = sqrt(dx*dx + dy*dy)
        
        var angle = atan2(dy, dx) * 180.0 / .pi // -180 to 180
        if angle < 0 { angle += 360.0 }
        
        // Find matching slice (reverse order to hit test outer ring first)
        for slice in slices.reversed() {
            if distance >= slice.innerRadius && distance <= slice.outerRadius {
                if angle >= slice.startAngle && angle <= slice.endAngle {
                    return slice
                }
            }
        }
        return nil
    }
}

struct SunburstSlice: Identifiable {
    let id = UUID()
    let node: FileNode
    let startAngle: Double
    let endAngle: Double
    let innerRadius: Double
    let outerRadius: Double
    let color: Color
}

struct SunburstTooltip: View {
    let slice: SunburstSlice
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(slice.node.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            
            Text(slice.node.formattedSize)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            
            if slice.node.isDirectory {
                Text("\(slice.node.children.count) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let ext = slice.node.extension {
                Text("Type: \(ext.uppercased())")
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
