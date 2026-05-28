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

import Foundation
import SwiftUI

enum ByteFormatter {
    static func string(from bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum FileTypeColors {
    static func color(for node: FileNode) -> Color {
        if node.isDirectory {
            return folderColor(for: node)
        }
        
        guard let ext = node.extension?.lowercased() else {
            return .gray
        }
        
        return color(forExtension: ext)
    }
    
    static func color(forExtension ext: String) -> Color {
        let normalizedExt = ext.lowercased()
        switch normalizedExt {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "webp", "svg", "ico":
            return Color(red: 0.35, green: 0.65, blue: 0.95)
        case "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpg", "mpeg":
            return Color(red: 0.95, green: 0.35, blue: 0.55)
        case "mp3", "aac", "wav", "flac", "m4a", "ogg", "wma", "aiff":
            return Color(red: 0.55, green: 0.35, blue: 0.95)
        case "pdf":
            return Color(red: 0.95, green: 0.55, blue: 0.35)
        case "doc", "docx", "txt", "rtf", "pages", "md", "tex":
            return Color(red: 0.35, green: 0.85, blue: 0.55)
        case "xls", "xlsx", "csv", "numbers":
            return Color(red: 0.35, green: 0.95, blue: 0.65)
        case "ppt", "pptx", "keynote":
            return Color(red: 0.95, green: 0.75, blue: 0.35)
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg":
            return Color(red: 0.65, green: 0.65, blue: 0.65)
        case "app", "exe", "dll", "so", "dylib":
            return Color(red: 0.75, green: 0.55, blue: 0.95)
        case "swift", "c", "cpp", "h", "m", "mm", "py", "js", "ts", "rb", "go", "rs", "java", "kt", "scala", "php", "html", "css", "xml", "json", "yaml", "toml":
            return Color(red: 0.35, green: 0.75, blue: 0.95)
        default:
            return hashColor(for: normalizedExt)
        }
    }
    
    private static func folderColor(for node: FileNode) -> Color {
        let colors: [Color] = [
            Color(red: 0.25, green: 0.55, blue: 0.85),
            Color(red: 0.25, green: 0.75, blue: 0.55),
            Color(red: 0.85, green: 0.55, blue: 0.25),
            Color(red: 0.75, green: 0.25, blue: 0.55),
            Color(red: 0.55, green: 0.25, blue: 0.85),
        ]
        return colors[abs(node.id.hashValue) % colors.count]
    }
    
    private static func hashColor(for string: String) -> Color {
        var hash: UInt64 = 0
        for char in string.unicodeScalars {
            hash = UInt64(char.value) &+ ((hash &<< 5) &- hash)
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.85)
    }
}
