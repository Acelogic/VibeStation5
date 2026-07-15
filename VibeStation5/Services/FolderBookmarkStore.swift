// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum BookmarkStoreError: Error, LocalizedError {
    case duplicate
    case stale
    case unavailable

    var errorDescription: String? {
        switch self {
        case .duplicate: "That folder is already in the library."
        case .stale: "The saved folder permission is stale. Add the folder again."
        case .unavailable: "The saved folder could not be opened."
        }
    }
}

@MainActor
final class FolderBookmarkStore {
    private let defaults: UserDefaults
    private let key = "VibeStation5.importedFolders.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [ImportedFolder] {
        guard let data = defaults.data(forKey: key),
              let folders = try? JSONDecoder().decode([ImportedFolder].self, from: data)
        else {
            return []
        }
        return folders
    }

    func add(_ url: URL, to existing: [ImportedFolder]) throws -> [ImportedFolder] {
        let bookmark = try url.bookmarkData(
            options: Self.creationOptions,
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        )
        let canonicalPath = url.standardizedFileURL.path
        for folder in existing {
            if let resolved = try? Self.resolve(folder), resolved.standardizedFileURL.path == canonicalPath {
                throw BookmarkStoreError.duplicate
            }
        }

        var folders = existing
        folders.append(ImportedFolder(
            id: UUID(),
            displayName: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            bookmark: bookmark,
            addedAt: .now
        ))
        folders.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        save(folders)
        return folders
    }

    func remove(id: UUID, from existing: [ImportedFolder]) -> [ImportedFolder] {
        let folders = existing.filter { $0.id != id }
        save(folders)
        return folders
    }

    func save(_ folders: [ImportedFolder]) {
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: key)
        }
    }

    nonisolated static func resolve(_ folder: ImportedFolder) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: folder.bookmark,
            options: resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw BookmarkStoreError.stale }
        return url
    }

    private static var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    private nonisolated static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope, .withoutUI]
        #else
        [.withoutUI]
        #endif
    }
}

