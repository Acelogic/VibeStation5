// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isImportingFolder = false

    var body: some View {
        List {
            Section("Boot") {
                Picker("Default boot mode", selection: $model.bootMode) {
                    ForEach(BootMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            Section("Just-in-Time Compilation") {
                Toggle("Use JIT when externally enabled", isOn: $model.jitEnabled)

                Label(model.jitStatus.title, systemImage: model.jitStatus.systemImage)
                    .foregroundStyle(jitStatusColor)
                Text(model.jitStatus.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.jitEnabled {
                    Button("Refresh JIT Status", systemImage: "arrow.clockwise") {
                        model.refreshJITStatus()
                    }

                    Link(
                        "SideStore / StikDebug Setup",
                        destination: URL(string: "https://docs.sidestore.io/docs/advanced/jit")!
                    )

                    DisclosureGroup("Signing and activation details") {
                        if model.jitStatus.requiresJITEntitlements {
                            LabeledContent(
                                "allow-jit",
                                value: model.jitStatus.allowJITEntitlement ? "Present" : "Missing"
                            )
                            LabeledContent(
                                "unsigned executable memory",
                                value: model.jitStatus.allowUnsignedExecutableMemoryEntitlement
                                    ? "Present"
                                    : "Missing"
                            )
                        }
                        if model.jitStatus.requiresExternalDebugger {
                            LabeledContent(
                                "get-task-allow",
                                value: model.jitStatus.getTaskAllowEntitlement ? "Present" : "Missing"
                            )
                            LabeledContent(
                                "Debugger activation",
                                value: model.jitStatus.debuggerAttached ? "Detected" : "Not detected"
                            )
                        }
                        if model.jitStatus.isTXMConstrained {
                            LabeledContent("Memory security", value: "iPadOS 26+ TXM")
                        }
                    }
                }
            }

            Section("Game Folders") {
                ForEach(model.folders) { folder in
                    HStack {
                        Label(folder.displayName, systemImage: "folder.fill")
                        Spacer()
                        Button("Remove", role: .destructive) {
                            Task { await model.removeFolder(id: folder.id) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder", systemImage: "folder.badge.plus") {
                    isImportingFolder = true
                }
            }

            if !model.scanIssues.isEmpty {
                Section("Folder Warnings") {
                    ForEach(model.scanIssues) { issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.folderName).font(.headline)
                            Text(issue.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Privacy") {
                Label("Imported folders are read-only", systemImage: "lock.shield.fill")
                Label("No firmware, games, or keys are bundled", systemImage: "shippingbox")
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            model.refreshJITStatus()
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

    private var jitStatusColor: Color {
        switch model.jitStatus.availability {
        case .ready:
            VibeTheme.green
        case .disabled:
            .secondary
        case .armed, .waitingForDebugger:
            VibeTheme.yellow
        case .missingEntitlements, .unavailable:
            VibeTheme.red
        }
    }
}
