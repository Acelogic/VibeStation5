// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

actor GameLibraryScanner {
    private let fileManager = FileManager.default
    private let maximumDepth = 8
    private let maximumCoverBytes = 20 * 1_024 * 1_024

    func scan(_ folders: [ImportedFolder]) -> LibraryScanResult {
        var gamesByID: [String: Game] = [:]
        var issues: [LibraryScanIssue] = []

        for folder in folders {
            do {
                let root = try FolderBookmarkStore.resolve(folder)
                let scoped = root.startAccessingSecurityScopedResource()
                defer {
                    if scoped { root.stopAccessingSecurityScopedResource() }
                }
                try scanFolder(folder, root: root, gamesByID: &gamesByID)
            } catch {
                issues.append(LibraryScanIssue(
                    folderName: folder.displayName,
                    message: error.localizedDescription
                ))
            }
        }

        let games = gamesByID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return LibraryScanResult(games: games, issues: issues)
    }

    private func scanFolder(
        _ folder: ImportedFolder,
        root: URL,
        gamesByID: inout [String: Game]
    ) throws {
        if try registerGameIfPresent(
            in: root,
            folder: folder,
            root: root,
            gamesByID: &gamesByID
        ) {
            return
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw BookmarkStoreError.unavailable
        }

        for case let url as URL in enumerator {
            let relative = relativePath(of: url, under: root)
            let depth = relative.split(separator: "/").count
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { continue }
            if depth > maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            if try registerGameIfPresent(
                in: url,
                folder: folder,
                root: root,
                gamesByID: &gamesByID
            ) {
                enumerator.skipDescendants()
            }
        }
    }

    private func registerGameIfPresent(
        in directory: URL,
        folder: ImportedFolder,
        root: URL,
        gamesByID: inout [String: Game]
    ) throws -> Bool {
        let executable = directory.appendingPathComponent("eboot.bin", isDirectory: false)
        let values: URLResourceValues
        do {
            values = try executable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            return false
        }
        guard values.isRegularFile != false else { return false }

        let relative = relativePath(of: executable, under: root)
        let metadata = readMetadata(beside: executable)
        let name = metadata.title ?? directory.lastPathComponent
        let identifier = "\(folder.id.uuidString):\(relative.lowercased())"
        gamesByID[identifier] = Game(
            id: identifier,
            rootID: folder.id,
            name: name.isEmpty ? "Unknown Game" : name,
            titleID: metadata.titleID,
            executableRelativePath: relative,
            executableSize: Int64(values.fileSize ?? 0),
            coverData: readCover(beside: executable)
        )
        return true
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func readMetadata(beside executable: URL) -> (title: String?, titleID: String?) {
        let paramURL = executable
            .deletingLastPathComponent()
            .appendingPathComponent("sce_sys", isDirectory: true)
            .appendingPathComponent("param.json", isDirectory: false)
        guard let data = try? Data(contentsOf: paramURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, nil)
        }

        let titleID = (root["titleId"] as? String).flatMap(Self.nonEmpty)
        guard let localized = root["localizedParameters"] as? [String: Any] else {
            return (nil, titleID)
        }

        if let language = localized["defaultLanguage"] as? String,
           let block = localized[language] as? [String: Any],
           let title = (block["titleName"] as? String).flatMap(Self.nonEmpty) {
            return (title, titleID)
        }

        for value in localized.values {
            guard let block = value as? [String: Any],
                  let title = (block["titleName"] as? String).flatMap(Self.nonEmpty)
            else { continue }
            return (title, titleID)
        }
        return (nil, titleID)
    }

    private func readCover(beside executable: URL) -> Data? {
        let sceSys = executable.deletingLastPathComponent().appendingPathComponent("sce_sys", isDirectory: true)
        for filename in ["icon0.png", "pic0.png"] {
            let url = sceSys.appendingPathComponent(filename, isDirectory: false)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  size <= maximumCoverBytes
            else { continue }
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
