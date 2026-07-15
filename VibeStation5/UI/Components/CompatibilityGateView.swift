// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct CompatibilityGateView: View {
    let support: PlatformSupport

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [VibeTheme.background, Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 22) {
                Image(systemName: "ipad.and.iphone.slash")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(VibeTheme.yellow)
                Text("Unsupported iPad Configuration")
                    .font(.largeTitle.bold())
                Text("VibeStation5 is intentionally limited to macOS and the 1 TB / 16 GB iPad Pro M4 or M5 configurations.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 620)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(support.reasons, id: \.self) { reason in
                        Label(reason, systemImage: "xmark.circle.fill")
                            .foregroundStyle(VibeTheme.red)
                    }
                }
                .padding(22)
                .vibePanel()
                Text("Detected: \(support.modelIdentifier) • \(ByteCountFormatter.string(fromByteCount: Int64(clamping: support.memoryBytes), countStyle: .memory)) RAM")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(40)
        }
        .ignoresSafeArea()
    }
}

