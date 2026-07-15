// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation

#if os(iOS) && !targetEnvironment(simulator)
@_silgen_name("csops")
private func vs5_csops(
    _ pid: pid_t,
    _ operation: UInt32,
    _ userAddress: UnsafeMutableRawPointer?,
    _ userSize: Int
) -> Int32
#endif

enum JITAvailability: Equatable, Sendable {
    case disabled
    case missingEntitlements([String])
    case waitingForDebugger
    case armed
    case ready
    case unavailable(String)
}

struct JITCapabilityStatus: Equatable, Sendable {
    let requested: Bool
    let allowJITEntitlement: Bool
    let allowUnsignedExecutableMemoryEntitlement: Bool
    let getTaskAllowEntitlement: Bool
    let debuggerAttached: Bool
    let requiresExternalDebugger: Bool
    let requiresJITEntitlements: Bool
    let isTXMConstrained: Bool
    let runningUnderXcode: Bool
    let probeSucceeded: Bool?
    let availability: JITAvailability

    var isReady: Bool {
        availability == .ready
    }

    var title: String {
        switch availability {
        case .disabled:
            return "JIT disabled"
        case .missingEntitlements:
            return "JIT signing incomplete"
        case .waitingForDebugger:
            return "Waiting for StikDebug"
        case .armed:
            return "JIT activation detected"
        case .ready:
            return "JIT memory ready"
        case .unavailable:
            return "JIT unavailable"
        }
    }

    var detail: String {
        switch availability {
        case .disabled:
            return "Enable JIT below to use it when an external debugger has activated the process."
        case let .missingEntitlements(keys):
            return "This build is missing: \(keys.joined(separator: ", ")). Rebuild or sideload the JIT-enabled target."
        case .waitingForDebugger:
            if isTXMConstrained, runningUnderXcode {
                return "iPadOS 26+ TXM requires a normal app launch followed by StikDebug activation; the Xcode debugger path is not compatible."
            }
            if isTXMConstrained {
                return "Launch VibeStation5 normally, connect LocalDevVPN, then select VibeStation5 in StikDebug. iPadOS 26+ TXM support remains app-specific."
            }
            return "Connect LocalDevVPN and select VibeStation5 in StikDebug or SideStore to attach the debugger and enable JIT."
        case .armed:
            return "Debugger activation is present. Refresh the status to verify MAP_JIT executable memory."
        case .ready:
            return "Debugger activation was detected and the MAP_JIT writable/executable-memory probe succeeded."
        case let .unavailable(reason):
            return "The debugger is active, but MAP_JIT allocation failed: \(reason)"
        }
    }

    var systemImage: String {
        switch availability {
        case .ready:
            return "bolt.fill"
        case .armed:
            return "bolt.badge.checkmark"
        case .waitingForDebugger:
            return "cable.connector"
        case .disabled:
            return "bolt.slash"
        case .missingEntitlements, .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }
}

enum JITCapability {
    private static let codeSigningStatusOperation: UInt32 = 0
    private static let codeSigningDebuggedFlag: UInt32 = 0x1000_0000

    static func inspect(requested: Bool, runProbe: Bool = true) -> JITCapabilityStatus {
        let allowJIT = entitlementIsTrue("com.apple.security.cs.allow-jit")
        let allowUnsignedExecutableMemory = entitlementIsTrue(
            "com.apple.security.cs.allow-unsigned-executable-memory"
        )
        let getTaskAllow = entitlementIsTrue("get-task-allow") ||
            entitlementIsTrue("com.apple.security.get-task-allow")
        let requiresDebugger = platformRequiresExternalDebugger
        let requiresEntitlements = platformRequiresJITEntitlements
        let debuggerAttached = processHasDebuggedCodeSigningStatus
        let txmConstrained = platformIsTXMConstrained
        let underXcode = ProcessInfo.processInfo.environment["XCODE_PRODUCT_BUILD_VERSION"] != nil

        var probeSucceeded: Bool?
        var probeError: String?
        let prerequisitesPresent = (!requiresEntitlements ||
            (allowJIT && allowUnsignedExecutableMemory)) &&
            (!requiresDebugger || getTaskAllow)
        let activationPresent = !requiresDebugger ||
            (debuggerAttached && !(txmConstrained && underXcode))

        if requested, runProbe, prerequisitesPresent, activationPresent {
            let result = probeExecutableMemory()
            probeSucceeded = result.succeeded
            probeError = result.error
        }

        return evaluate(
            requested: requested,
            allowJIT: allowJIT,
            allowUnsignedExecutableMemory: allowUnsignedExecutableMemory,
            getTaskAllow: getTaskAllow,
            debuggerAttached: debuggerAttached,
            requiresExternalDebugger: requiresDebugger,
            requiresJITEntitlements: requiresEntitlements,
            isTXMConstrained: txmConstrained,
            runningUnderXcode: underXcode,
            probeSucceeded: probeSucceeded,
            probeError: probeError
        )
    }

    static func evaluate(
        requested: Bool,
        allowJIT: Bool,
        allowUnsignedExecutableMemory: Bool,
        getTaskAllow: Bool,
        debuggerAttached: Bool,
        requiresExternalDebugger: Bool,
        requiresJITEntitlements: Bool,
        isTXMConstrained: Bool,
        runningUnderXcode: Bool,
        probeSucceeded: Bool?,
        probeError: String? = nil
    ) -> JITCapabilityStatus {
        let availability: JITAvailability
        if !requested {
            availability = .disabled
        } else {
            var missing: [String] = []
            if requiresJITEntitlements {
                if !allowJIT {
                    missing.append("com.apple.security.cs.allow-jit")
                }
                if !allowUnsignedExecutableMemory {
                    missing.append("com.apple.security.cs.allow-unsigned-executable-memory")
                }
            }
            if requiresExternalDebugger, !getTaskAllow {
                missing.append("get-task-allow")
            }

            if !missing.isEmpty {
                availability = .missingEntitlements(missing)
            } else if requiresExternalDebugger,
                      (!debuggerAttached || (isTXMConstrained && runningUnderXcode)) {
                availability = .waitingForDebugger
            } else if probeSucceeded == nil {
                availability = .armed
            } else if probeSucceeded == true {
                availability = .ready
            } else {
                availability = .unavailable(probeError ?? "unknown error")
            }
        }

        return JITCapabilityStatus(
            requested: requested,
            allowJITEntitlement: allowJIT,
            allowUnsignedExecutableMemoryEntitlement: allowUnsignedExecutableMemory,
            getTaskAllowEntitlement: getTaskAllow,
            debuggerAttached: debuggerAttached,
            requiresExternalDebugger: requiresExternalDebugger,
            requiresJITEntitlements: requiresJITEntitlements,
            isTXMConstrained: isTXMConstrained,
            runningUnderXcode: runningUnderXcode,
            probeSucceeded: probeSucceeded,
            availability: availability
        )
    }

    private static var platformRequiresExternalDebugger: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private static var platformRequiresJITEntitlements: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private static var platformIsTXMConstrained: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        #else
        false
        #endif
    }

    private static var processHasDebuggedCodeSigningStatus: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        var flags: UInt32 = 0
        let result = withUnsafeMutableBytes(of: &flags) { buffer in
            vs5_csops(
                getpid(),
                codeSigningStatusOperation,
                buffer.baseAddress,
                buffer.count
            )
        }
        return result == 0 && (flags & codeSigningDebuggedFlag) != 0
        #else
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.environment["XCODE_PRODUCT_BUILD_VERSION"] != nil
        #endif
    }

    private static func entitlementIsTrue(_ name: String) -> Bool {
        typealias CreateTask = @convention(c) (CFAllocator?) -> OpaquePointer?
        typealias CopyEntitlement = @convention(c) (
            OpaquePointer,
            CFString,
            UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFTypeRef>?

        guard let handle = dlopen(
            "/System/Library/Frameworks/Security.framework/Security",
            RTLD_LAZY | RTLD_LOCAL
        )
        else {
            return false
        }
        defer { dlclose(handle) }
        guard let createSymbol = dlsym(handle, "SecTaskCreateFromSelf"),
              let copySymbol = dlsym(handle, "SecTaskCopyValueForEntitlement")
        else {
            return false
        }

        let createTask = unsafeBitCast(createSymbol, to: CreateTask.self)
        let copyEntitlement = unsafeBitCast(copySymbol, to: CopyEntitlement.self)
        guard let task = createTask(nil) else { return false }
        defer {
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(task)).release()
        }
        guard let value = copyEntitlement(task, name as CFString, nil)?.takeRetainedValue()
        else {
            return false
        }
        return (value as? Bool) == true
    }

    private static func probeExecutableMemory() -> (succeeded: Bool, error: String?) {
        let allocationSize = Int(getpagesize())
        errno = 0
        let address = mmap(
            nil,
            allocationSize,
            PROT_READ | PROT_WRITE | PROT_EXEC,
            MAP_PRIVATE | MAP_ANON | MAP_JIT,
            -1,
            0
        )
        guard address != MAP_FAILED, let address else {
            let code = errno
            return (false, "\(String(cString: strerror(code))) (errno \(code))")
        }
        defer { munmap(address, allocationSize) }

        setJITWriteProtection(enabled: false)
        var returnInstruction = UInt32(0xD65F_03C0).littleEndian
        withUnsafeBytes(of: &returnInstruction) { bytes in
            address.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        setJITWriteProtection(enabled: true)
        return (true, nil)
    }

    private static func setJITWriteProtection(enabled: Bool) {
        typealias JITWriteProtect = @convention(c) (Int32) -> Void
        guard let handle = dlopen(nil, RTLD_LAZY | RTLD_LOCAL) else { return }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "pthread_jit_write_protect_np") else { return }
        let function = unsafeBitCast(symbol, to: JITWriteProtect.self)
        function(enabled ? 1 : 0)
    }
}
