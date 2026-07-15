// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

enum VibeTheme {
    static let background = Color(red: 0.025, green: 0.035, blue: 0.075)
    static let panel = Color(red: 0.055, green: 0.075, blue: 0.14)
    static let panelHighlight = Color(red: 0.075, green: 0.105, blue: 0.20)
    static let blue = Color(red: 0.18, green: 0.48, blue: 1.0)
    static let purple = Color(red: 0.58, green: 0.30, blue: 1.0)
    static let green = Color(red: 0.28, green: 0.82, blue: 0.55)
    static let yellow = Color(red: 0.93, green: 0.69, blue: 0.24)
    static let red = Color(red: 0.95, green: 0.34, blue: 0.40)
}

struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(VibeTheme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }
    }
}

extension View {
    func vibePanel() -> some View {
        modifier(PanelModifier())
    }
}

