// Disk Inventory Zed - duplicate analysis models
//
// Copyright (C) 2026 Matt Ivan
// Licensed under GPL-3.0-or-later.

import Foundation

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
