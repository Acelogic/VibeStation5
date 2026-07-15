// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct ImportedFolder: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var bookmark: Data
    let addedAt: Date
}

struct Game: Identifiable, Hashable, Sendable {
    let id: String
    let rootID: UUID
    let name: String
    let titleID: String?
    let executableRelativePath: String
    let executableSize: Int64
    let coverData: Data?

    var initials: String {
        let pieces = name
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap(\.first)
            .filter { $0.isLetter || $0.isNumber }
            .prefix(2)
        let value = String(pieces).uppercased()
        return value.isEmpty ? "?" : value
    }

    var detail: String {
        if let titleID {
            return "\(titleID)  •  \(Self.sizeFormatter.string(fromByteCount: executableSize))"
        }
        return Self.sizeFormatter.string(fromByteCount: executableSize)
    }

    static func == (lhs: Game, rhs: Game) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()
}

struct LibraryScanIssue: Identifiable, Hashable, Sendable {
    let id = UUID()
    let folderName: String
    let message: String
}

struct LibraryScanResult: Sendable {
    let games: [Game]
    let issues: [LibraryScanIssue]
}

