// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import VibeStation5

final class JITCapabilityTests: XCTestCase {
    func testDisabledPreferenceKeepsInterpreterFallback() {
        let status = makeStatus(requested: false)

        XCTAssertEqual(status.availability, .disabled)
        XCTAssertFalse(status.isReady)
    }

    func testMissingSigningEntitlementsAreReported() {
        let status = makeStatus(
            getTaskAllow: false
        )

        XCTAssertEqual(
            status.availability,
            .missingEntitlements(["get-task-allow"])
        )
    }

    func testMacHardenedRuntimeRequiresJITEntitlements() {
        let status = makeStatus(
            allowJIT: false,
            allowUnsignedExecutableMemory: false,
            requiresExternalDebugger: false,
            requiresJITEntitlements: true
        )

        XCTAssertEqual(
            status.availability,
            .missingEntitlements([
                "com.apple.security.cs.allow-jit",
                "com.apple.security.cs.allow-unsigned-executable-memory"
            ])
        )
    }

    func testSideloadedBuildWaitsForExternalDebugger() {
        let status = makeStatus(debuggerAttached: false)

        XCTAssertEqual(status.availability, .waitingForDebugger)
        XCTAssertTrue(status.detail.contains("StikDebug"))
    }

    func testTXMBuildRejectsXcodeDebuggerPath() {
        let status = makeStatus(
            debuggerAttached: true,
            isTXMConstrained: true,
            runningUnderXcode: true
        )

        XCTAssertEqual(status.availability, .waitingForDebugger)
        XCTAssertTrue(status.detail.contains("normal app launch"))
    }

    func testSuccessfulMemoryProbeMarksJITReady() {
        let status = makeStatus(debuggerAttached: true, probeSucceeded: true)

        XCTAssertEqual(status.availability, .ready)
        XCTAssertTrue(status.isReady)
    }

    func testFailedMemoryProbePreservesReason() {
        let status = makeStatus(
            debuggerAttached: true,
            probeSucceeded: false,
            probeError: "Operation not permitted"
        )

        XCTAssertEqual(status.availability, .unavailable("Operation not permitted"))
        XCTAssertTrue(status.detail.contains("Operation not permitted"))
    }

    private func makeStatus(
        requested: Bool = true,
        allowJIT: Bool = true,
        allowUnsignedExecutableMemory: Bool = true,
        getTaskAllow: Bool = true,
        debuggerAttached: Bool = false,
        requiresExternalDebugger: Bool = true,
        requiresJITEntitlements: Bool = false,
        isTXMConstrained: Bool = false,
        runningUnderXcode: Bool = false,
        probeSucceeded: Bool? = nil,
        probeError: String? = nil
    ) -> JITCapabilityStatus {
        JITCapability.evaluate(
            requested: requested,
            allowJIT: allowJIT,
            allowUnsignedExecutableMemory: allowUnsignedExecutableMemory,
            getTaskAllow: getTaskAllow,
            debuggerAttached: debuggerAttached,
            requiresExternalDebugger: requiresExternalDebugger,
            requiresJITEntitlements: requiresJITEntitlements,
            isTXMConstrained: isTXMConstrained,
            runningUnderXcode: runningUnderXcode,
            probeSucceeded: probeSucceeded,
            probeError: probeError
        )
    }
}
