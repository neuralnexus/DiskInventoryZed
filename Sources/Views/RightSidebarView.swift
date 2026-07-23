// Disk Inventory Zed — analysis sidebar
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

import SwiftUI

struct RightSidebarView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var section: AnalysisSection = .types
    @State private var showDiagnostics = false

    private enum AnalysisSection: String, CaseIterable, Identifiable {
        case types = "Types"
        case largest = "Largest"
        case review = "Review"
        case changes = "Changes"

        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            scanSummary

            Picker("Analysis", selection: $section) {
                ForEach(AnalysisSection.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Group {
                switch section {
                case .types:
                    fileTypes
                case .largest:
                    largestFiles
                case .review:
                    reviewCandidates
                case .changes:
                    comparisonView
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            selectionInspector
                .frame(minHeight: 245, idealHeight: 280, maxHeight: 330)
        }
    }

    private var scanSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scan Summary")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                if viewModel.isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let root = viewModel.rootNode {
                HStack {
                    SummaryMetric(
                        title: "On disk",
                        value: root.formattedSize
                    )
                    Spacer()
                    SummaryMetric(
                        title: "Files",
                        value: viewModel.totalFiles.formatted()
                    )
                    Spacer()
                    SummaryMetric(
                        title: "Folders",
                        value: viewModel.totalDirectories.formatted()
                    )
                }
            }

            if viewModel.scanDiagnostics.unreadableItems > 0 ||
               viewModel.scanDiagnostics.skippedDirectories > 0 ||
               viewModel.scanDiagnostics.revisitedDirectories > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(scanCaveat)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        showDiagnostics.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showDiagnostics) {
                        ScanDiagnosticsView(diagnostics: viewModel.scanDiagnostics)
                    }
                }
            }
        }
        .padding(12)
    }

    private var scanCaveat: String {
        var parts: [String] = []
        if viewModel.scanDiagnostics.unreadableItems > 0 {
            parts.append("\(viewModel.scanDiagnostics.unreadableItems) unreadable")
        }
        if viewModel.scanDiagnostics.skippedDirectories > 0 {
            parts.append("\(viewModel.scanDiagnostics.skippedDirectories) skipped")
        }
        if viewModel.scanDiagnostics.revisitedDirectories > 0 {
            parts.append("\(viewModel.scanDiagnostics.revisitedDirectories) links not re-followed")
        }
        return parts.joined(separator: " · ")
    }

    private var fileTypes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Space by file type")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.selectedExtension != nil {
                    Button("Clear filter") {
                        viewModel.selectedExtension = nil
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)

            if viewModel.extensionStats.isEmpty {
                analysisPlaceholder
            } else {
                List(viewModel.extensionStats.prefix(100)) { stat in
                    Button {
                        viewModel.selectedExtension =
                            viewModel.selectedExtension == stat.ext ? nil : stat.ext
                    } label: {
                        ExtensionRow(
                            stat: stat,
                            isSelected: viewModel.selectedExtension == stat.ext
                        )
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private var largestFiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Largest files in this scan")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            if viewModel.largestFiles.isEmpty {
                analysisPlaceholder
            } else {
                List(viewModel.largestFiles) { node in
                    NodeInsightRow(node: node) {
                        viewModel.focus(node: node)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var reviewCandidates: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Old large files", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text("At least 100 MB and not modified in a year.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if viewModel.oldLargeFiles.isEmpty {
                        Text("No candidates found")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(viewModel.oldLargeFiles.prefix(25)) { node in
                            NodeInsightRow(node: node) {
                                viewModel.focus(node: node)
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Label("Possible duplicates", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Same byte size. Full contents must be verified before cleanup.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if viewModel.duplicateCandidates.isEmpty {
                        Text("No candidates found")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else if let progress = viewModel.duplicateVerificationProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(
                                value: Double(progress.completedFiles),
                                total: Double(max(1, progress.totalFiles))
                            )
                            Text(progress.phase.rawValue)
                                .font(.system(size: 10, weight: .medium))
                            Text(progress.currentPath)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Cancel Verification") {
                                viewModel.cancelDuplicateVerification()
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 5)
                    } else if viewModel.didVerifyDuplicates {
                        if viewModel.verifiedDuplicates.isEmpty {
                            Label("No content-identical duplicates found", systemImage: "checkmark.shield")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 5)
                        } else {
                            ForEach(viewModel.verifiedDuplicates.prefix(30)) { group in
                                VerifiedDuplicateGroupView(group: group)
                            }
                        }

                        if !viewModel.duplicateVerificationUnreadablePaths.isEmpty {
                            Text("\(viewModel.duplicateVerificationUnreadablePaths.count) candidates changed or could not be read.")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }

                        Button("Verify Again") {
                            viewModel.verifyDuplicateCandidates()
                        }
                        .controlSize(.small)
                    } else {
                        ForEach(viewModel.duplicateCandidates.prefix(12)) { candidate in
                            DuplicateCandidateView(candidate: candidate)
                        }
                        Button {
                            viewModel.verifyDuplicateCandidates()
                        } label: {
                            Label("Verify Contents with SHA-256", systemImage: "checkmark.shield")
                        }
                        .controlSize(.small)
                        .help("Reads candidate files and confirms exact content matches. No files are changed.")
                    }
                }
            }
            .padding(12)
        }
    }

    private var comparisonView: some View {
        Group {
            if viewModel.isComparingSnapshot {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Comparing snapshot…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let comparison = viewModel.scanComparison {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Since \(comparison.baselineDate.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(signedByteCount(comparison.totalDelta))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(comparison.totalDelta > 0 ? .orange : .green)
                            }
                            Spacer()
                            Button("Clear") {
                                viewModel.clearComparison()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                        }

                        HStack {
                            SummaryMetric(title: "Added", value: comparison.addedCount.formatted())
                            Spacer()
                            SummaryMetric(title: "Removed", value: comparison.removedCount.formatted())
                            Spacer()
                            SummaryMetric(title: "Resized", value: comparison.changedCount.formatted())
                        }

                        comparisonSection(
                            title: "Largest growth",
                            icon: "arrow.up.right",
                            changes: comparison.largestGrowth
                        )
                        Divider()
                        comparisonSection(
                            title: "Largest reductions",
                            icon: "arrow.down.right",
                            changes: comparison.largestShrinkage
                        )
                    }
                    .padding(12)
                }
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.title2)
                    Text("Compare this scan with an earlier snapshot")
                        .font(.system(size: 11, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text("Use Export → Export Snapshot after a scan. Later, scan the same location and choose Compare with Snapshot.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    @ViewBuilder
    private func comparisonSection(
        title: String,
        icon: String,
        changes: [ScanChange]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
            if changes.isEmpty {
                Text("No changes")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(changes.prefix(25)) { change in
                    ScanChangeRow(change: change) {
                        if let node = change.currentNode {
                            viewModel.focus(node: node)
                        }
                    }
                }
            }
        }
    }

    private func signedByteCount(_ value: Int64) -> String {
        if value == 0 { return "No net change" }
        let sign = value > 0 ? "+" : "−"
        let magnitude = value == Int64.min ? Int64.max : Swift.abs(value)
        return sign + ByteFormatter.string(from: magnitude)
    }

    private var analysisPlaceholder: some View {
        VStack(spacing: 8) {
            if viewModel.isAnalyzing {
                ProgressView()
                    .controlSize(.small)
                Text("Building analysis…")
            } else {
                Image(systemName: "chart.bar.doc.horizontal")
                Text("No matching files")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectionInspector: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Selection")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)

            if let node = viewModel.selectedNode ?? viewModel.currentNode {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: node))
                        .font(.system(size: 18))
                        .foregroundStyle(FileTypeColors.color(for: node))
                    Text(node.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                }

                Divider()
                DetailItem(label: "Kind", value: kindName(for: node))
                DetailItem(label: "On disk", value: node.formattedSize)
                DetailItem(label: "Logical", value: node.formattedLogicalSize)
                if node.isDirectory {
                    DetailItem(label: "Children", value: node.children.count.formatted())
                }
                if let modified = node.modificationDate {
                    DetailItem(
                        label: "Modified",
                        value: modified.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if node.isHardLinkDuplicate {
                    Label("Storage counted at another hard link", systemImage: "link")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let issue = node.errorDescription {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }

                Text(node.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)

                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.path, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button {
                        viewModel.revealInFinder(node: node)
                    } label: {
                        Label("Finder", systemImage: "folder")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("No item selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.black.opacity(0.02))
    }

    private func icon(for node: FileNode) -> String {
        if node.isSymbolicLink { return "link" }
        if node.isPackage { return "shippingbox" }
        switch node.kind {
        case .directory: return "folder"
        case .package: return "shippingbox"
        case .symbolicLink: return "link"
        case .file: return "doc"
        }
    }

    private func kindName(for node: FileNode) -> String {
        if node.isSymbolicLink && node.isDirectory { return "Symbolic-link folder" }
        if node.isPackage && node.isDirectory { return "Package folder" }
        switch node.kind {
        case .directory: return "Folder"
        case .package: return "Package"
        case .symbolicLink: return "Symbolic link"
        case .file: return "File"
        }
    }
}

private struct ScanDiagnosticsView: View {
    let diagnostics: ScanDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan Diagnostics")
                .font(.headline)

            DetailItem(label: "Unreadable items", value: diagnostics.unreadableItems.formatted())
            DetailItem(label: "Skipped folders", value: diagnostics.skippedDirectories.formatted())
            DetailItem(label: "Symbolic links", value: diagnostics.symbolicLinks.formatted())
            DetailItem(label: "Packages", value: diagnostics.packages.formatted())
            DetailItem(label: "Hard-link duplicates", value: diagnostics.duplicateHardLinks.formatted())
            DetailItem(label: "Targets not re-followed", value: diagnostics.revisitedDirectories.formatted())

            if !diagnostics.firstUnreadablePaths.isEmpty {
                Divider()
                Text("First unreadable paths")
                    .font(.system(size: 11, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(diagnostics.firstUnreadablePaths, id: \.self) { path in
                            Text(path)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
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

            Text(stat.ext == "unknown" ? "NO EXTENSION" : stat.ext.uppercased())
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer()

            Text(stat.fileCount.formatted())
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(ByteFormatter.string(from: stat.totalSize))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }
}

private struct NodeInsightRow: View {
    let node: FileNode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "doc")
                    .foregroundStyle(FileTypeColors.color(for: node))
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.displayName)
                        .lineLimit(1)
                    Text(node.url.deletingLastPathComponent().path)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(node.formattedSize)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
            }
        }
    }
}

private struct DuplicateCandidateView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let candidate: DuplicateCandidate

    var body: some View {
        DisclosureGroup {
            VStack(spacing: 5) {
                ForEach(candidate.files) { node in
                    NodeInsightRow(node: node) {
                        viewModel.focus(node: node)
                    }
                }
            }
            .padding(.top, 5)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text("\(candidate.files.count) files · up to \(ByteFormatter.string(from: candidate.potentialSavings))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

private struct VerifiedDuplicateGroupView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let group: VerifiedDuplicateGroup

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                Text("SHA-256 \(group.digest.prefix(16))…")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                ForEach(group.files) { node in
                    NodeInsightRow(node: node) {
                        viewModel.focus(node: node)
                    }
                }
            }
            .padding(.top, 5)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Label(
                    "\(group.files.count) verified identical files",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
                Text("Up to \(ByteFormatter.string(from: group.potentialSavings)) reclaimable")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ScanChangeRow: View {
    let change: ScanChange
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(change.delta >= 0 ? .orange : .green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(change.displayName)
                        .lineLimit(1)
                    Text(change.path)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(deltaLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
            }
            .font(.system(size: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(change.currentNode == nil)
        .help(change.currentNode == nil ? "This item is no longer present." : change.path)
    }

    private var icon: String {
        switch change.kind {
        case .added: return "plus.circle"
        case .removed: return "minus.circle"
        case .grew: return "arrow.up.right"
        case .shrank: return "arrow.down.right"
        }
    }

    private var deltaLabel: String {
        let sign = change.delta >= 0 ? "+" : "−"
        let magnitude = change.delta == Int64.min ? Int64.max : Swift.abs(change.delta)
        return sign + ByteFormatter.string(from: magnitude)
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
                .lineLimit(1)
        }
    }
}
