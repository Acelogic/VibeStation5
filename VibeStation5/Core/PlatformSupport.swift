// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Darwin

struct PlatformSupport: Equatable, Sendable {
    static let minimumMemoryBytes: UInt64 = 15_000_000_000
    static let minimumOneTerabyteBytes: Int64 = 800_000_000_000
    static let maximumOneTerabyteBytes: Int64 = 1_300_000_000_000

    static let supportedIPadModels: Set<String> = [
        "iPad16,3", "iPad16,4", // 11-inch iPad Pro (M4)
        "iPad16,5", "iPad16,6", // 13-inch iPad Pro (M4)
        "iPad17,1", "iPad17,2", // 11-inch iPad Pro (M5)
        "iPad17,3", "iPad17,4", // 13-inch iPad Pro (M5)
    ]

    let isSupported: Bool
    let platformName: String
    let modelIdentifier: String
    let memoryBytes: UInt64
    let storageBytes: Int64?
    let reasons: [String]

    static var current: PlatformSupport {
        #if os(macOS)
        evaluate(
            deviceIdentifier: machineIdentifier(),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            storageBytes: volumeCapacity(),
            isMac: true,
            isSimulator: false
        )
        #elseif targetEnvironment(simulator)
        evaluate(
            deviceIdentifier: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iPad Simulator",
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            storageBytes: volumeCapacity(),
            isMac: false,
            isSimulator: true
        )
        #else
        evaluate(
            deviceIdentifier: machineIdentifier(),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            storageBytes: volumeCapacity(),
            isMac: false,
            isSimulator: false
        )
        #endif
    }

    static func evaluate(
        deviceIdentifier: String,
        memoryBytes: UInt64,
        storageBytes: Int64?,
        isMac: Bool,
        isSimulator: Bool
    ) -> PlatformSupport {
        if isMac {
            return PlatformSupport(
                isSupported: true,
                platformName: "macOS",
                modelIdentifier: deviceIdentifier,
                memoryBytes: memoryBytes,
                storageBytes: storageBytes,
                reasons: []
            )
        }

        if isSimulator {
            return PlatformSupport(
                isSupported: true,
                platformName: "iPadOS Simulator",
                modelIdentifier: deviceIdentifier,
                memoryBytes: memoryBytes,
                storageBytes: storageBytes,
                reasons: ["Hardware enforcement is bypassed in Simulator builds."]
            )
        }

        var reasons: [String] = []
        if !supportedIPadModels.contains(deviceIdentifier) {
            reasons.append("Requires an 11-inch or 13-inch iPad Pro with M4 or M5.")
        }
        if memoryBytes < minimumMemoryBytes {
            reasons.append("Requires the 16 GB unified-memory configuration.")
        }
        guard let storageBytes else {
            reasons.append("The device storage capacity could not be verified.")
            return PlatformSupport(
                isSupported: false,
                platformName: "iPadOS",
                modelIdentifier: deviceIdentifier,
                memoryBytes: memoryBytes,
                storageBytes: nil,
                reasons: reasons
            )
        }
        if storageBytes < minimumOneTerabyteBytes || storageBytes > maximumOneTerabyteBytes {
            reasons.append("Requires the 1 TB storage configuration.")
        }

        return PlatformSupport(
            isSupported: reasons.isEmpty,
            platformName: "iPadOS",
            modelIdentifier: deviceIdentifier,
            memoryBytes: memoryBytes,
            storageBytes: storageBytes,
            reasons: reasons
        )
    }

    private static func machineIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: value)
    }

    private static func volumeCapacity() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let capacity = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity else {
            return nil
        }
        return Int64(capacity)
    }
}

