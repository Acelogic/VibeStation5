// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct SupportDetailsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label("Supported Host", systemImage: "checkmark.seal.fill")
                    .font(.largeTitle.bold())
                    .foregroundStyle(VibeTheme.green)

                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Platform", value: model.platformSupport.platformName)
                    LabeledContent("Model", value: model.platformSupport.modelIdentifier)
                    LabeledContent(
                        "Physical memory",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: model.platformSupport.memoryBytes),
                            countStyle: .memory
                        )
                    )
                    if let storage = model.platformSupport.storageBytes {
                        LabeledContent(
                            "Storage capacity",
                            value: ByteCountFormatter.string(fromByteCount: storage, countStyle: .decimal)
                        )
                    }
                }
                .padding(20)
                .vibePanel()

                VStack(alignment: .leading, spacing: 12) {
                    Text("iPad Target")
                        .font(.title2.bold())
                    Text("11-inch and 13-inch iPad Pro (M4 or M5), specifically the 1 TB configuration with 16 GB unified memory. The app checks model family, physical memory, and formatted volume capacity on launch.")
                        .foregroundStyle(.secondary)
                    Text("macOS Target")
                        .font(.title2.bold())
                        .padding(.top, 6)
                    Text("macOS 14 or newer. The portable loader and SwiftUI shell build natively on Mac from the same source tree.")
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .vibePanel()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Port Status")
                        .font(.title2.bold())
                    status("SwiftUI application and game library", complete: true)
                    status("PS4/PS5 SELF and 64-bit ELF preflight", complete: true)
                    status("Sparse guest virtual memory", complete: true)
                    status("x86-64 interpreter/AOT backend", complete: false)
                    status("SharpEmu HLE service surface", complete: false)
                    status("Metal renderer", complete: false)
                }
                .padding(20)
                .vibePanel()
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .background(VibeTheme.background)
        .navigationTitle("Host & Port Status")
    }

    private func status(_ text: String, complete: Bool) -> some View {
        Label(text, systemImage: complete ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(complete ? VibeTheme.green : VibeTheme.yellow)
    }
}

