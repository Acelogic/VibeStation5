// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import VibeStation5

final class PlatformSupportTests: XCTestCase {
    func testOneTerabyteM4AndM5IPadsPass() {
        for identifier in ["iPad16,3", "iPad16,6", "iPad17,1", "iPad17,4"] {
            let support = PlatformSupport.evaluate(
                deviceIdentifier: identifier,
                memoryBytes: 16_000_000_000,
                storageBytes: 1_000_000_000_000,
                isMac: false,
                isSimulator: false
            )
            XCTAssertTrue(support.isSupported, identifier)
        }
    }

    func testTwoTerabyteConfigurationIsRejected() {
        let support = PlatformSupport.evaluate(
            deviceIdentifier: "iPad17,4",
            memoryBytes: 16_000_000_000,
            storageBytes: 2_000_000_000_000,
            isMac: false,
            isSimulator: false
        )
        XCTAssertFalse(support.isSupported)
        XCTAssertTrue(support.reasons.contains(where: { $0.contains("1 TB") }))
    }

    func testEarlierIPadProIsRejectedEvenWithMemoryAndStorage() {
        let support = PlatformSupport.evaluate(
            deviceIdentifier: "iPad14,5",
            memoryBytes: 16_000_000_000,
            storageBytes: 1_000_000_000_000,
            isMac: false,
            isSimulator: false
        )
        XCTAssertFalse(support.isSupported)
        XCTAssertTrue(support.reasons.contains(where: { $0.contains("M4 or M5") }))
    }

    func testMacAndSimulatorAreSupported() {
        XCTAssertTrue(PlatformSupport.evaluate(
            deviceIdentifier: "Mac16,1",
            memoryBytes: 8_000_000_000,
            storageBytes: 256_000_000_000,
            isMac: true,
            isSimulator: false
        ).isSupported)
        XCTAssertTrue(PlatformSupport.evaluate(
            deviceIdentifier: "iPad16,6",
            memoryBytes: 1,
            storageBytes: 1,
            isMac: false,
            isSimulator: true
        ).isSupported)
    }
}

