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

