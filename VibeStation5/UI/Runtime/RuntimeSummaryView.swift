// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct RuntimeSummaryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section("Runtime") {
                HStack(spacing: 14) {
                    Image(systemName: model.runtimeStage.systemImage)
                        .font(.title2)
                        .foregroundStyle(stageColor)
                    VStack(alignment: .leading) {
                        Text(model.runtimeStage.rawValue)
                            .font(.headline)
                        Text(model.selectedGame?.name ?? "No game selected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let preparation = model.preparation {
                Section("Prepared Image") {
                    LabeledContent("Format", value: preparation.format.rawValue)
                    LabeledContent("Entry point", value: preparation.entryPointText)
                    LabeledContent("Loadable segments", value: "\(preparation.loadableSegmentCount)")
                    LabeledContent(
                        "Reserved memory",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: preparation.reservedMemoryBytes),
                            countStyle: .binary
                        )
                    )
                }
            }

            Section("Execution Backend") {
                Label("SELF and ELF preflight", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VibeTheme.green)
                Label("Sparse virtual-memory map", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VibeTheme.green)
                Label("ARM-native x86-64 interpreter", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VibeTheme.green)
                Label(
                    model.jitStatus.title,
                    systemImage: model.jitStatus.systemImage
                )
                .foregroundStyle(model.jitStatus.isReady ? VibeTheme.green : VibeTheme.yellow)
                Label("Base relocations and HLE import thunks", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VibeTheme.green)
                Label("Cooperative guest threads and core HLE", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VibeTheme.green)
                Label("Dreaming Sarah menu-ready AGC flip", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VibeTheme.green)
                Label("Metal guest video surface", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VibeTheme.green)
                Label("Dreaming Sarah menu milestone surface", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VibeTheme.green)
                Label("General AGC draw rasterization pending", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(VibeTheme.yellow)
            }
        }
        .navigationTitle("Runtime")
        .toolbar {
            Button("Clear", systemImage: "trash") {
                model.clearRuntime()
            }
        }
    }

    private var stageColor: Color {
        switch model.runtimeStage {
        case .idle: .secondary
        case .preparing: VibeTheme.blue
        case .ready: VibeTheme.green
        case .running: VibeTheme.blue
        case .launched: VibeTheme.green
        case .stopped: VibeTheme.yellow
        case .failed: VibeTheme.red
        }
    }
}
