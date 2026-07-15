// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum BootMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case game = "Game"
    case systemUI = "System UI"

    var id: Self { self }
}

enum RuntimeStage: String, Sendable {
    case idle = "Idle"
    case preparing = "Preparing"
    case ready = "Image Ready"
    case running = "Running on ARM"
    case launched = "Guest Launch Reached"
    case stopped = "Guest Stopped"
    case failed = "Failed"

    var systemImage: String {
        switch self {
        case .idle: "power"
        case .preparing: "hourglass"
        case .ready: "checkmark.circle.fill"
        case .running: "cpu.fill"
        case .launched: "play.circle.fill"
        case .stopped: "stop.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

enum RuntimeLogSeverity: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case success = "OK"
    case warning = "WARN"
    case error = "ERROR"
}

struct RuntimeLog: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let severity: RuntimeLogSeverity
    let message: String

    init(_ severity: RuntimeLogSeverity, _ message: String, timestamp: Date = .now) {
        self.timestamp = timestamp
        self.severity = severity
        self.message = message
    }
}

enum ExecutableFormat: String, Sendable {
    case decryptedELF = "Decrypted ELF"
    case ps4SELF = "PS4 SELF"
    case ps5SELF = "PS5 SELF"
}

struct RuntimePreparation: Sendable {
    let format: ExecutableFormat
    let entryPoint: UInt64
    let programHeaderCount: Int
    let loadableSegmentCount: Int
    let reservedMemoryBytes: UInt64
    let loadedMemoryBytes: UInt64
    let encryptedSegmentCount: Int
    let compressedSegmentCount: Int
    let appliedRelocationCount: Int
    let importSymbolCount: Int
    let cpuBackend: String

    var entryPointText: String {
        String(format: "0x%016llX", entryPoint)
    }
}
