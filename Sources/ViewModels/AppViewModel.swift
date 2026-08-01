// Disk Inventory Zed — a modern, fast, native disk usage visualizer
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

import AppKit
import Foundation
import SwiftUI

struct UserSettings {
    private static let defaults = UserDefaults.standard

    static var lastScanPath: String? {
        get { defaults.string(forKey: "lastScanPath") }
        set { defaults.set(newValue, forKey: "lastScanPath") }
    }

    static var defaultViewMode: AppViewModel.ViewMode {
        get {
            let rawValue = defaults.string(forKey: "defaultViewMode") ?? AppViewModel.ViewMode.treemap.rawValue
            return AppViewModel.ViewMode(rawValue: rawValue) ?? .treemap
        }
        set { defaults.set(newValue.rawValue, forKey: "defaultViewMode") }
    }

    static var defaultSortOrder: AppViewModel.SortOrder {
        get {
            let rawValue = defaults.string(forKey: "defaultSortOrder") ?? AppViewModel.SortOrder.sizeDescending.rawValue
            return AppViewModel.SortOrder(rawValue: rawValue) ?? .sizeDescending
        }
        set { defaults.set(newValue.rawValue, forKey: "defaultSortOrder") }
    }

    static var skipDeveloperFolders: Bool {
        get { defaults.object(forKey: "skipDeveloperFolders") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "skipDeveloperFolders") }
    }

    static var sizeThreshold: Int64 {
        get { defaults.object(forKey: "sizeThreshold") as? Int64 ?? 0 }
        set { defaults.set(newValue, forKey: "sizeThreshold") }
    }

    static var showHiddenFiles: Bool {
        get { defaults.object(forKey: "showHiddenFiles") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "showHiddenFiles") }
    }

    static var showPackageContents: Bool {
        get { defaults.object(forKey: "showPackageContents") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showPackageContents") }
    }

    static var followSymlinks: Bool {
        get { defaults.object(forKey: "followSymlinks") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "followSymlinks") }
    }
}

struct ExtensionStat: Identifiable, Hashable {
    var id: String { ext }
    let ext: String
    let totalSize: Int64
    let fileCount: Int

    var color: Color {
        FileTypeColors.color(forExtension: ext)
    }
}

struct DuplicateCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let fileSize: Int64
    let files: [FileNode]

    var displayName: String {
        let names = Set(files.map { $0.displayName.lowercased() })
        if names.count == 1, let name = files.first?.displayName {
            return name
        }
        return "\(files.count) same-sized files"
    }

    var potentialSavings: Int64 {
        files.dropFirst().reduce(Int64(0)) { $0 + $1.allocatedSize }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var rootNode: FileNode?
    @Published private(set) var currentNode: FileNode?
    @Published var selectedNode: FileNode?
    @Published private(set) var breadcrumb: [FileNode] = []
    @Published private(set) var isScanning = false
    @Published private(set) var totalFiles = 0
    @Published private(set) var totalDirectories = 0
    @Published private(set) var scanProgressFiles = 0
    @Published private(set) var scanProgressDirectories = 0
    @Published private(set) var scanProgressUnreadableItems = 0
    @Published private(set) var scanDuration: TimeInterval = 0
    @Published private(set) var scanStatusPath = ""
    @Published private(set) var scanDiagnostics = ScanDiagnostics.empty
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var viewMode: ViewMode = UserSettings.defaultViewMode {
        didSet { UserSettings.defaultViewMode = viewMode }
    }
    @Published var sortOrder: SortOrder = UserSettings.defaultSortOrder {
        didSet { UserSettings.defaultSortOrder = sortOrder }
    }
    @Published var searchQuery = "" {
        didSet { scheduleSearch() }
    }
    @Published var searchScope: SearchScope = .entireScan {
        didSet { scheduleSearch() }
    }
    @Published private(set) var searchResults: [FileNode] = []
    @Published private(set) var extensionStats: [ExtensionStat] = []
    @Published var selectedExtension: String?
    @Published var sizeThreshold: Int64 = UserSettings.sizeThreshold {
        didSet { UserSettings.sizeThreshold = sizeThreshold }
    }
    @Published var skipDeveloperFolders = UserSettings.skipDeveloperFolders {
        didSet { UserSettings.skipDeveloperFolders = skipDeveloperFolders }
    }
    @Published var showHiddenFiles = UserSettings.showHiddenFiles {
        didSet { UserSettings.showHiddenFiles = showHiddenFiles }
    }
    @Published var showPackageContents = UserSettings.showPackageContents {
        didSet { UserSettings.showPackageContents = showPackageContents }
    }
    @Published var followSymlinks = UserSettings.followSymlinks {
        didSet { UserSettings.followSymlinks = followSymlinks }
    }
    @Published private(set) var largestFiles: [FileNode] = []
    @Published private(set) var oldLargeFiles: [FileNode] = []
    @Published private(set) var duplicateCandidates: [DuplicateCandidate] = []
    @Published private(set) var verifiedDuplicates: [VerifiedDuplicateGroup] = []
    @Published private(set) var duplicateVerificationProgress: DuplicateVerificationProgress?
    @Published private(set) var duplicateVerificationUnreadablePaths: [String] = []
    @Published private(set) var didVerifyDuplicates = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var pendingTrashNode: FileNode?
    @Published private(set) var scanComparison: ScanComparison?
    @Published private(set) var isComparingSnapshot = false

    private var navigationStack: [FileNode] = []
    private var navigationIndex = -1
    private var activeScanID: UUID?
    private var scanTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var duplicateVerificationTask: Task<Void, Never>?
    private var comparisonTask: Task<Void, Never>?
    private var comparisonOperationID: UUID?
    private var searchIndex: [SearchIndexEntry] = []

    var canNavigateBack: Bool { navigationIndex > 0 }
    var canNavigateForward: Bool { navigationIndex >= 0 && navigationIndex < navigationStack.count - 1 }

    enum ViewMode: String, CaseIterable {
        case treemap = "Treemap"
        case sunburst = "Sunburst"
        case list = "List"

        var icon: String {
            switch self {
            case .treemap: return "square.grid.2x2"
            case .sunburst: return "circle.dashed"
            case .list: return "list.bullet"
            }
        }
    }

    enum SortOrder: String, CaseIterable {
        case sizeDescending = "Size (Large First)"
        case sizeAscending = "Size (Small First)"
        case nameAscending = "Name (A-Z)"
        case nameDescending = "Name (Z-A)"

        var icon: String {
            switch self {
            case .sizeDescending: return "arrow.down"
            case .sizeAscending: return "arrow.up"
            case .nameAscending: return "textformat.abc"
            case .nameDescending: return "textformat.abc.dottedunderline"
            }
        }
    }

    enum SearchScope: String, CaseIterable {
        case entireScan = "Entire Scan"
        case currentFolder = "Current Folder"
    }

    var filteredChildren: [FileNode] {
        guard let node = currentNode else { return [] }
        let candidates = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? node.children
            : searchResults

        let filtered = candidates.filter { candidate in
            if sizeThreshold > 0 && candidate.size < sizeThreshold { return false }
            if let selectedExtension {
                return candidate.extension?.lowercased() == selectedExtension.lowercased()
            }
            return true
        }

        switch sortOrder {
        case .sizeDescending:
            return filtered.sorted {
                $0.size == $1.size
                    ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    : $0.size > $1.size
            }
        case .sizeAscending:
            return filtered.sorted {
                $0.size == $1.size
                    ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    : $0.size < $1.size
            }
        case .nameAscending:
            return filtered.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .nameDescending:
            return filtered.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedDescending
            }
        }
    }

    func scan(url: URL) {
        scanTask?.cancel()
        analysisTask?.cancel()
        searchTask?.cancel()
        duplicateVerificationTask?.cancel()
        comparisonTask?.cancel()
        comparisonTask = nil
        comparisonOperationID = nil

        let scanID = UUID()
        activeScanID = scanID
        isScanning = true
        scanProgressFiles = 0
        scanProgressDirectories = 0
        scanProgressUnreadableItems = 0
        scanStatusPath = url.path
        errorMessage = nil
        showError = false
        duplicateVerificationProgress = nil
        isAnalyzing = false
        pendingTrashNode = nil
        isComparingSnapshot = false

        let options = ScanOptions(
            skipDeveloperFolders: skipDeveloperFolders,
            showHiddenFiles: showHiddenFiles,
            showPackageContents: showPackageContents,
            followSymlinks: followSymlinks
        )

        scanTask = Task { [weak self] in
            guard let self else { return }
            let scanner = DiskScanner()

            do {
                let result = try await scanner.scan(url: url, options: options) { [weak self] snapshot in
                    guard let self, self.activeScanID == scanID else { return }
                    self.scanProgressFiles = snapshot.files
                    self.scanProgressDirectories = snapshot.directories
                    self.scanProgressUnreadableItems = snapshot.unreadableItems
                    self.scanStatusPath = snapshot.currentPath
                }

                try Task.checkCancellation()
                guard self.activeScanID == scanID else { return }

                UserSettings.lastScanPath = url.path
                self.rootNode = result.root
                self.currentNode = result.root
                self.selectedNode = nil
                self.breadcrumb = [result.root]
                self.navigationStack = [result.root]
                self.navigationIndex = 0
                self.totalFiles = result.totalFiles
                self.totalDirectories = result.totalDirectories
                self.scanDuration = result.duration
                self.scanDiagnostics = result.diagnostics
                self.scanStatusPath = result.root.path
                self.isScanning = false
                self.scanProgressFiles = 0
                self.scanProgressDirectories = 0
                self.scanProgressUnreadableItems = 0
                self.searchResults = []
                self.extensionStats = []
                self.largestFiles = []
                self.oldLargeFiles = []
                self.duplicateCandidates = []
                self.verifiedDuplicates = []
                self.duplicateVerificationProgress = nil
                self.duplicateVerificationUnreadablePaths = []
                self.didVerifyDuplicates = false
                self.searchIndex = []
                self.scanComparison = nil
                self.startAnalysis(for: result.root, scanID: scanID)
            } catch is CancellationError {
                if self.activeScanID == scanID {
                    self.isScanning = false
                    self.resetScanProgress()
                }
            } catch {
                guard self.activeScanID == scanID else { return }
                self.isScanning = false
                self.resetScanProgress()
                self.errorMessage = error.localizedDescription
                self.showError = true
            }
        }
    }

    func cancelScan() {
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        resetScanProgress()
    }

    func rescan() {
        if let rootNode {
            scan(url: rootNode.url)
        }
    }

    func navigateTo(node: FileNode) {
        guard node.isDirectory else {
            selectedNode = node
            return
        }

        if navigationIndex < navigationStack.count - 1 {
            navigationStack.removeSubrange((navigationIndex + 1)...)
        }
        if navigationStack.last?.id != node.id {
            navigationStack.append(node)
            navigationIndex = navigationStack.count - 1
        }
        setCurrentNode(node)
    }

    func navigateBack() {
        guard canNavigateBack else { return }
        navigationIndex -= 1
        setCurrentNode(navigationStack[navigationIndex])
    }

    func navigateForward() {
        guard canNavigateForward else { return }
        navigationIndex += 1
        setCurrentNode(navigationStack[navigationIndex])
    }

    func navigateUp() {
        guard breadcrumb.count > 1 else { return }
        navigateTo(node: breadcrumb[breadcrumb.count - 2])
    }

    func navigateToRoot() {
        if let rootNode {
            navigateTo(node: rootNode)
        }
    }

    func focus(node: FileNode) {
        guard let rootNode,
              let path = rootNode.path(to: node.id) else {
            selectedNode = node
            return
        }

        if node.isDirectory {
            navigateTo(node: node)
            return
        }

        let parent = path.dropLast().last ?? rootNode
        navigateTo(node: parent)
        selectedNode = node
    }

    func revealInFinder(node: FileNode) {
        NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "")
    }

    func openContainingFolder(node: FileNode) {
        NSWorkspace.shared.open(node.url.deletingLastPathComponent())
    }

    func openFile(node: FileNode) {
        NSWorkspace.shared.open(node.url)
    }

    func moveToTrash(node: FileNode) {
        if let safetyError = cleanupSafetyError(for: node) {
            presentError(safetyError)
            return
        }

        pendingTrashNode = node
    }

    func cancelMoveToTrash() {
        pendingTrashNode = nil
    }

    func confirmMoveToTrash() {
        guard let node = pendingTrashNode else { return }
        pendingTrashNode = nil
        if let safetyError = cleanupSafetyError(for: node) {
            presentError(safetyError)
            return
        }

        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            guard let rootNode else { return }

            let removedCounts = node.descendantCounts()
            let currentID = currentNode?.id
            let updatedRoot = rootNode.removingDescendant(withID: node.id)
            self.rootNode = updatedRoot
            totalFiles = max(0, totalFiles - removedCounts.files)
            totalDirectories = max(0, totalDirectories - removedCounts.directories)

            let nextCurrent = currentID.flatMap { updatedRoot.findChild(withID: $0) } ?? updatedRoot
            currentNode = nextCurrent
            breadcrumb = updatedRoot.path(to: nextCurrent.id) ?? [updatedRoot]
            selectedNode = nil
            navigationStack = breadcrumb
            navigationIndex = navigationStack.count - 1

            if let scanID = activeScanID {
                startAnalysis(for: updatedRoot, scanID: scanID)
            }
        } catch {
            presentError("Failed to move to Trash: \(error.localizedDescription)")
        }
    }

    func verifyDuplicateCandidates() {
        duplicateVerificationTask?.cancel()
        guard !duplicateCandidates.isEmpty else {
            verifiedDuplicates = []
            duplicateVerificationUnreadablePaths = []
            duplicateVerificationProgress = nil
            didVerifyDuplicates = true
            return
        }

        let candidates = duplicateCandidates
        let rootID = rootNode?.id
        didVerifyDuplicates = false
        verifiedDuplicates = []
        duplicateVerificationUnreadablePaths = []
        duplicateVerificationProgress = DuplicateVerificationProgress(
            phase: .sampling,
            completedFiles: 0,
            totalFiles: candidates.reduce(0) { $0 + $1.files.count },
            currentPath: ""
        )

        duplicateVerificationTask = Task { [weak self] in
            do {
                let result = try await DuplicateVerifier.verify(candidates: candidates) { [weak self] progress in
                    guard let self, self.rootNode?.id == rootID else { return }
                    self.duplicateVerificationProgress = progress
                }
                try Task.checkCancellation()
                guard let self, self.rootNode?.id == rootID else { return }
                self.verifiedDuplicates = result.groups
                self.duplicateVerificationUnreadablePaths = result.unreadablePaths
                self.duplicateVerificationProgress = nil
                self.didVerifyDuplicates = true
            } catch is CancellationError {
                guard let self else { return }
                self.duplicateVerificationProgress = nil
            } catch {
                guard let self else { return }
                self.duplicateVerificationProgress = nil
                self.presentError("Duplicate verification failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelDuplicateVerification() {
        duplicateVerificationTask?.cancel()
        duplicateVerificationTask = nil
        duplicateVerificationProgress = nil
    }

    func compareWithSnapshot(at url: URL) {
        comparisonTask?.cancel()
        guard let rootNode else { return }
        let operationID = UUID()
        comparisonOperationID = operationID
        isComparingSnapshot = true
        scanComparison = nil

        comparisonTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let snapshot = try ScanExporter.importSnapshot(from: url)
                return try ScanSnapshotComparator.compare(current: rootNode, with: snapshot)
            }
            do {
                let comparison = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }

                try Task.checkCancellation()
                guard let self,
                      self.comparisonOperationID == operationID,
                      self.rootNode === rootNode else { return }
                self.scanComparison = comparison
                self.isComparingSnapshot = false
                self.comparisonTask = nil
                self.comparisonOperationID = nil
            } catch is CancellationError {
                guard let self, self.comparisonOperationID == operationID else { return }
                self.isComparingSnapshot = false
                self.comparisonTask = nil
                self.comparisonOperationID = nil
            } catch {
                guard let self, self.comparisonOperationID == operationID else { return }
                self.isComparingSnapshot = false
                self.comparisonTask = nil
                self.comparisonOperationID = nil
                self.presentError("Failed to compare snapshot: \(error.localizedDescription)")
            }
        }
    }

    func clearComparison() {
        comparisonTask?.cancel()
        comparisonTask = nil
        comparisonOperationID = nil
        scanComparison = nil
        isComparingSnapshot = false
    }

    func exportScanData(to url: URL) {
        guard let rootNode else { return }
        let diagnostics = scanDiagnostics

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ScanExporter.exportJSON(root: rootNode, diagnostics: diagnostics, to: url)
                }.value
            } catch {
                self.errorMessage = "Failed to export JSON: \(error.localizedDescription)"
                self.showError = true
            }
        }
    }

    func exportCSV(to url: URL) {
        guard let rootNode else { return }

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ScanExporter.exportCSV(root: rootNode, to: url)
                }.value
            } catch {
                self.errorMessage = "Failed to export CSV: \(error.localizedDescription)"
                self.showError = true
            }
        }
    }

    func restoreLastScan() {
        guard let path = UserSettings.lastScanPath,
              FileManager.default.fileExists(atPath: path) else {
            return
        }
        scan(url: URL(fileURLWithPath: path))
    }

    private func setCurrentNode(_ node: FileNode) {
        currentNode = node
        selectedNode = nil
        breadcrumb = rootNode?.path(to: node.id) ?? [node]
        scheduleSearch()
    }

    private func startAnalysis(for root: FileNode, scanID: UUID) {
        analysisTask?.cancel()
        isAnalyzing = true

        analysisTask = Task { [weak self] in
            let analysis = await Task.detached(priority: .userInitiated) {
                Self.analyze(root: root)
            }.value

            guard let self,
                  !Task.isCancelled,
                  self.activeScanID == scanID,
                  self.rootNode?.id == root.id else {
                return
            }

            self.extensionStats = analysis.extensions.map {
                ExtensionStat(ext: $0.ext, totalSize: $0.totalSize, fileCount: $0.fileCount)
            }
            self.largestFiles = analysis.largestFiles
            self.oldLargeFiles = analysis.oldLargeFiles
            self.duplicateCandidates = analysis.duplicateCandidates
            self.searchIndex = analysis.searchIndex
            self.isAnalyzing = false
            self.scheduleSearch()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        let index = searchIndex
        let scopePath = searchScope == .currentFolder ? (currentNode?.path ?? "") : ""
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                try Task.checkCancellation()
            } catch {
                return
            }

            let normalizedQuery = query.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let matches = await Task.detached(priority: .userInitiated) {
                var results: [FileNode] = []
                results.reserveCapacity(200)

                for entry in index {
                    if Task.isCancelled { return results }
                    let isInScope = scopePath.isEmpty ||
                        entry.path == scopePath ||
                        entry.path.hasPrefix(scopePath.hasSuffix("/") ? scopePath : scopePath + "/")
                    if isInScope &&
                       (entry.searchableName.contains(normalizedQuery) ||
                        entry.searchablePath.contains(normalizedQuery)) {
                        results.append(entry.node)
                        if results.count == 2_000 { break }
                    }
                }
                return results
            }.value

            guard let self,
                  !Task.isCancelled,
                  self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                return
            }
            self.searchResults = matches
        }
    }

    nonisolated private static func analyze(root: FileNode) -> ScanAnalysis {
        var extensions: [String: ExtensionAggregate] = [:]
        var files: [FileNode] = []
        var searchIndex: [SearchIndexEntry] = []
        var duplicateGroups: [String: [FileNode]] = [:]
        let oldFileCutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast

        var stack = [root]
        while let node = stack.popLast() {
            searchIndex.append(SearchIndexEntry(
                node: node,
                path: node.path,
                searchableName: node.displayName.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ),
                searchablePath: node.path.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
            ))

            if node.isDirectory {
                stack.append(contentsOf: node.children)
                continue
            }

            files.append(node)
            let ext = (node.extension?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            var aggregate = extensions[ext] ?? ExtensionAggregate(ext: ext, totalSize: 0, fileCount: 0)
            aggregate.totalSize += node.size
            aggregate.fileCount += 1
            extensions[ext] = aggregate

            if node.kind == .file,
               node.logicalSize >= 10_000_000,
               !node.isHardLinkDuplicate {
                let key = String(node.logicalSize)
                duplicateGroups[key, default: []].append(node)
            }
        }

        let largestFiles = files.sorted { $0.size > $1.size }.prefix(100)
        let oldLargeFiles = files
            .filter {
                $0.size >= 100_000_000 &&
                ($0.modificationDate ?? .distantFuture) < oldFileCutoff
            }
            .sorted { $0.size > $1.size }
            .prefix(100)

        let candidates = duplicateGroups.compactMap { key, matches -> DuplicateCandidate? in
            guard matches.count > 1, let first = matches.first else { return nil }
            return DuplicateCandidate(
                id: key,
                fileSize: first.logicalSize,
                files: matches.sorted { $0.path < $1.path }
            )
        }
        .sorted { $0.potentialSavings > $1.potentialSavings }
        .prefix(500)

        return ScanAnalysis(
            extensions: extensions.values.sorted { $0.totalSize > $1.totalSize },
            largestFiles: Array(largestFiles),
            oldLargeFiles: Array(oldLargeFiles),
            duplicateCandidates: Array(candidates),
            searchIndex: searchIndex
        )
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }

    private func resetScanProgress() {
        scanProgressFiles = 0
        scanProgressDirectories = 0
        scanProgressUnreadableItems = 0
        scanStatusPath = rootNode?.path ?? ""
    }

    private func cleanupSafetyError(for node: FileNode) -> String? {
        guard let rootNode else { return "There is no active scan." }
        guard node.id != rootNode.id else {
            return "The root of the current scan cannot be moved to Trash."
        }

        let path = node.url.standardizedFileURL.path
        let protectedPaths: Set<String> = [
            "/",
            "/Applications",
            "/Library",
            "/System",
            "/Users",
            "/bin",
            "/cores",
            "/dev",
            "/etc",
            "/private",
            "/sbin",
            "/tmp",
            "/usr",
            "/var",
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        ]
        let protectedPrefixes = [
            "/System/",
            "/bin/",
            "/cores/",
            "/dev/",
            "/etc/",
            "/private/",
            "/sbin/",
            "/usr/",
            "/var/"
        ]
        if protectedPaths.contains(path) ||
           protectedPrefixes.contains(where: { path.hasPrefix($0) }) {
            return "Disk Inventory Zed will not move this protected system location to Trash."
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return "The item no longer exists. Rescan the location to refresh the view."
        }
        return nil
    }
}

private struct ExtensionAggregate: Sendable {
    let ext: String
    var totalSize: Int64
    var fileCount: Int
}

private struct SearchIndexEntry: Sendable {
    let node: FileNode
    let path: String
    let searchableName: String
    let searchablePath: String
}

private struct ScanAnalysis: Sendable {
    let extensions: [ExtensionAggregate]
    let largestFiles: [FileNode]
    let oldLargeFiles: [FileNode]
    let duplicateCandidates: [DuplicateCandidate]
    let searchIndex: [SearchIndexEntry]
}
