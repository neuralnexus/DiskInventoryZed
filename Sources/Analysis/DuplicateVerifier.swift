// Disk Inventory Zed — content-verified duplicate analysis
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

struct DuplicateVerificationProgress: Sendable, Equatable {
    enum Phase: String, Equatable, Sendable {
        case sampling = "Sampling candidates"
        case hashing = "Verifying full contents"
    }

    let phase: Phase
    let completedFiles: Int
    let totalFiles: Int
    let currentPath: String
}

struct VerifiedDuplicateGroup: Identifiable, Hashable, Sendable {
    let digest: String
    let fileSize: Int64
    let files: [FileNode]

    var id: String { digest }

    var potentialSavings: Int64 {
        files.dropFirst().reduce(Int64(0)) { $0 + $1.allocatedSize }
    }
}

struct DuplicateVerificationResult: Sendable {
    let groups: [VerifiedDuplicateGroup]
    let unreadablePaths: [String]
}

enum DuplicateVerifier {
    private static let sampleSize = 64 * 1_024
    private static let readBufferSize = 1_024 * 1_024

    /// Verifies candidates in two passes. A small first/last-byte sample removes most
    /// false positives before a complete SHA-256 pass reads the entire file.
    static func verify(
        candidates: [DuplicateCandidate],
        progress: @escaping @MainActor @Sendable (DuplicateVerificationProgress) -> Void
    ) async throws -> DuplicateVerificationResult {
        var uniqueFiles: [String: FileNode] = [:]
        for candidate in candidates {
            for file in candidate.files where !file.isHardLinkDuplicate {
                uniqueFiles[file.id] = file
            }
        }

        let files = uniqueFiles.values.sorted { $0.path < $1.path }
        var unreadablePaths: [String] = []
        var samplesBySizeAndDigest: [String: [FileNode]] = [:]
        var completed = 0

        for file in files {
            try Task.checkCancellation()
            await progress(DuplicateVerificationProgress(
                phase: .sampling,
                completedFiles: completed,
                totalFiles: files.count,
                currentPath: file.path
            ))

            do {
                let digest = try sampleDigest(for: file)
                samplesBySizeAndDigest["\(file.logicalSize)|\(digest)", default: []].append(file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if unreadablePaths.count < 100 {
                    unreadablePaths.append(file.path)
                }
            }
            completed += 1
        }

        let filesNeedingFullHash = samplesBySizeAndDigest.values
            .filter { $0.count > 1 }
            .flatMap { $0 }
            .sorted { $0.path < $1.path }
        var fullHashes: [String: [FileNode]] = [:]
        completed = 0

        for file in filesNeedingFullHash {
            try Task.checkCancellation()
            await progress(DuplicateVerificationProgress(
                phase: .hashing,
                completedFiles: completed,
                totalFiles: filesNeedingFullHash.count,
                currentPath: file.path
            ))

            do {
                let digest = try fullDigest(for: file)
                fullHashes["\(file.logicalSize)|\(digest)", default: []].append(file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if unreadablePaths.count < 100 && !unreadablePaths.contains(file.path) {
                    unreadablePaths.append(file.path)
                }
            }
            completed += 1
        }

        let groups = fullHashes.compactMap { key, matches -> VerifiedDuplicateGroup? in
            guard matches.count > 1,
                  let separator = key.firstIndex(of: "|") else {
                return nil
            }
            let digest = String(key[key.index(after: separator)...])
            return VerifiedDuplicateGroup(
                digest: digest,
                fileSize: matches.first?.logicalSize ?? 0,
                files: matches.sorted { $0.path < $1.path }
            )
        }
        .sorted {
            if $0.potentialSavings == $1.potentialSavings {
                return $0.digest < $1.digest
            }
            return $0.potentialSavings > $1.potentialSavings
        }

        return DuplicateVerificationResult(
            groups: groups,
            unreadablePaths: unreadablePaths
        )
    }

    private static func sampleDigest(for node: FileNode) throws -> String {
        let before = try fingerprint(for: node.url)
        guard before.size == node.logicalSize else {
            throw VerificationError.fileChanged
        }
        let handle = try FileHandle(forReadingFrom: node.url)
        defer { try? handle.close() }

        var hasher = SHA256()
        hasher.update(data: Data(String(node.logicalSize).utf8))
        if let first = try handle.read(upToCount: sampleSize) {
            hasher.update(data: first)
        }

        if node.logicalSize > Int64(sampleSize) {
            let offset = UInt64(max(0, node.logicalSize - Int64(sampleSize)))
            try handle.seek(toOffset: offset)
            if let last = try handle.read(upToCount: sampleSize) {
                hasher.update(data: last)
            }
        }
        let digest = hexDigest(hasher.finalize())
        guard try fingerprint(for: node.url) == before else {
            throw VerificationError.fileChanged
        }
        return digest
    }

    private static func fullDigest(for node: FileNode) throws -> String {
        let before = try fingerprint(for: node.url)
        guard before.size == node.logicalSize else {
            throw VerificationError.fileChanged
        }
        let handle = try FileHandle(forReadingFrom: node.url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: readBufferSize),
                  !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        let digest = hexDigest(hasher.finalize())
        guard try fingerprint(for: node.url) == before else {
            throw VerificationError.fileChanged
        }
        return digest
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(for url: URL) throws -> FileFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw VerificationError.notRegularFile
        }
        return FileFingerprint(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }
}

private struct FileFingerprint: Equatable {
    let size: Int64
    let modificationDate: Date?
}

private enum VerificationError: Error {
    case fileChanged
    case notRegularFile
}
