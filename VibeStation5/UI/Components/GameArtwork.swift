// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct GameArtwork: View {
    let game: Game

    var body: some View {
        Group {
            if let image = platformImage {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: placeholderColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(game.initials)
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .clipped()
    }

    private var placeholderColors: [Color] {
        let palettes: [[Color]] = [
            [VibeTheme.blue, Color(red: 0.08, green: 0.16, blue: 0.34)],
            [VibeTheme.purple, Color(red: 0.18, green: 0.08, blue: 0.34)],
            [Color(red: 0.12, green: 0.52, blue: 0.56), Color(red: 0.05, green: 0.20, blue: 0.28)],
            [Color(red: 0.72, green: 0.29, blue: 0.44), Color(red: 0.27, green: 0.09, blue: 0.20)],
        ]
        let seed = game.name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palettes[abs(seed) % palettes.count]
    }

    private var platformImage: Image? {
        guard let data = game.coverData else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }
}

