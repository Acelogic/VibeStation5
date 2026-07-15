// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct GameDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let game = model.selectedGame {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 22) {
                        GameArtwork(game: game)
                            .frame(width: 180, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: VibeTheme.blue.opacity(0.25), radius: 24)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(game.name)
                                .font(.largeTitle.bold())
                            if let titleID = game.titleID {
                                Text(titleID)
                                    .font(.headline.monospaced())
                                    .foregroundStyle(VibeTheme.blue)
                            }
                            Text(game.detail)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Label(game.executableRelativePath, systemImage: "doc.badge.gearshape")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Boot Configuration")
                            .font(.title2.bold())
                        Picker("Boot mode", selection: $model.bootMode) {
                            ForEach(BootMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Button {
                                Task { await model.prepareSelectedGame() }
                            } label: {
                                Label("Prepare Image", systemImage: "memorychip")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(model.runtimeStage == .preparing)

                            Button {
                                Task { await model.attemptGuestStart() }
                            } label: {
                                Label("Start Guest", systemImage: "play.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(model.runtimeStage != .ready)
                        }
                    }
                    .padding(20)
                    .vibePanel()

                    if let preparation = model.preparation {
                        PreparationDetails(preparation: preparation)
                    }
                }
                .padding(28)
            }
            .background(VibeTheme.background)
            .navigationTitle(game.name)
        } else {
            ContentUnavailableView(
                "Select a Game",
                systemImage: "gamecontroller",
                description: Text("Choose a title from the library to inspect its executable and boot configuration.")
            )
        }
    }
}

private struct PreparationDetails: View {
    let preparation: RuntimePreparation

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Executable Preflight", systemImage: "checkmark.seal.fill")
                .font(.title2.bold())
                .foregroundStyle(VibeTheme.green)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                metric("Format", preparation.format.rawValue)
                metric("Entry point", preparation.entryPointText)
                metric("Program headers", "\(preparation.programHeaderCount)")
                metric("LOAD segments", "\(preparation.loadableSegmentCount)")
                metric("Reserved memory", format(preparation.reservedMemoryBytes))
                metric("File-backed payload", format(preparation.loadedMemoryBytes))
                metric("Relocations", preparation.appliedRelocationCount.formatted())
                metric("Import thunks", preparation.importSymbolCount.formatted())
                metric("CPU backend", preparation.cpuBackend)
            }
        }
        .padding(20)
        .vibePanel()
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced().weight(.medium))
                .textSelection(.enabled)
        }
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
}
