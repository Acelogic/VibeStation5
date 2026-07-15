// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isImportingFolder = false

    private let columns = [
        GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 18),
    ]

    var body: some View {
        Group {
            if model.folders.isEmpty {
                ContentUnavailableView {
                    Label("No Game Folders", systemImage: "externaldrive.badge.plus")
                } description: {
                    Text("Add a folder containing extracted games and eboot.bin files.")
                } actions: {
                    Button("Add Game Folder") { isImportingFolder = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.isScanning && model.games.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Scanning library…")
                        .foregroundStyle(.secondary)
                }
            } else if model.filteredGames.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.filteredGames) { game in
                            GameCard(game: game, isSelected: game.id == model.selectedGameID)
                                .onTapGesture { model.selectedGameID = game.id }
                        }
                    }
                    .padding(20)
                }
                .background(VibeTheme.background)
            }
        }
        .navigationTitle("Game Library")
        .searchable(text: $model.searchText, prompt: "Search games or title IDs")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshLibrary() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)

                Button {
                    isImportingFolder = true
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                Task { await model.addFolder(url) }
            case let .failure(error):
                model.alertMessage = error.localizedDescription
            }
        }
    }
}

private struct GameCard: View {
    let game: Game
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GameArtwork(game: game)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, VibeTheme.blue)
                            .padding(10)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(game.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(game.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(13)
        }
        .background(VibeTheme.panelHighlight, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(isSelected ? VibeTheme.blue : .white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

