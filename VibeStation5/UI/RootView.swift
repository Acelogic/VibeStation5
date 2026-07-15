// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case library = "Library"
    case runtime = "Runtime"
    case settings = "Settings"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .library: "square.grid.2x2.fill"
        case .runtime: "terminal.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var destination: SidebarDestination = .library

    var body: some View {
        Group {
            if model.platformSupport.isSupported {
                workspace
            } else {
                CompatibilityGateView(support: model.platformSupport)
            }
        }
        .tint(VibeTheme.blue)
        .background(VibeTheme.background)
        .alert(
            "VibeStation5",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            presenting: model.alertMessage
        ) { _ in
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var workspace: some View {
        NavigationSplitView {
            List {
                ForEach(SidebarDestination.allCases) { item in
                    Button {
                        destination = item
                    } label: {
                        Label(item.rawValue, systemImage: item.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(destination == item ? VibeTheme.blue.opacity(0.2) : Color.clear)
                }
            }
            .navigationTitle("VibeStation5")
            .safeAreaInset(edge: .bottom) {
                HostBadge(support: model.platformSupport)
                    .padding()
            }
        } content: {
            switch destination {
            case .library:
                LibraryView()
            case .runtime:
                RuntimeSummaryView()
            case .settings:
                SettingsView()
            }
        } detail: {
            switch destination {
            case .library:
                GameDetailView()
            case .runtime:
                RuntimeConsoleView()
            case .settings:
                SupportDetailsView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 620)
        #endif
    }
}

private struct HostBadge: View {
    let support: PlatformSupport

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(VibeTheme.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(support.platformName)
                    .font(.caption.weight(.semibold))
                Text(support.modelIdentifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
