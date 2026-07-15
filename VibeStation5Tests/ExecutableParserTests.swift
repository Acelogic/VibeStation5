// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import VibeStation5

final class ExecutableParserTests: XCTestCase {
    func testParsesAndMapsDecryptedELF() throws {
        var image = Data(repeating: 0, count: 0x110)
        writeELFHeader(into: &image, at: 0, entry: 0x400000, programHeaderCount: 1)
        writeUInt32LE(1, into: &image, at: 64)
        writeUInt32LE(5, into: &image, at: 68)
        writeUInt64LE(0x100, into: &image, at: 72)
        writeUInt64LE(0x400000, into: &image, at: 80)
        writeUInt64LE(0x400000, into: &image, at: 88)
        writeUInt64LE(4, into: &image, at: 96)
        writeUInt64LE(0x1000, into: &image, at: 104)
        writeUInt64LE(0x1000, into: &image, at: 112)
        image.replaceSubrange(0x100..<0x104, with: [0xDE, 0xAD, 0xBE, 0xEF])

        let parsed = try ExecutableParser().parse(image)
        XCTAssertEqual(parsed.format, .decryptedELF)
        XCTAssertEqual(parsed.elfHeader.entryPoint, 0x400000)
        XCTAssertEqual(parsed.loadableSegments.count, 1)

        let report = try ExecutableLoader().loadDecryptedELF(image, image: parsed)
        XCTAssertEqual(report.memory.reservedByteCount, 0x1000)
        XCTAssertEqual(report.loadedBytes, 4)
        XCTAssertEqual(try report.memory.read(at: 0x400000, length: 4), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testParsesPS5SELFLayout() throws {
        var image = Data(repeating: 0, count: 128)
        image.replaceSubrange(0..<12, with: SELFHeader.ps5Identifier)
        writeUInt64LE(128, into: &image, at: 16)
        writeUInt16LE(1, into: &image, at: 24)
        writeUInt16LE(0x52, into: &image, at: 26)
        writeUInt64LE(0xA, into: &image, at: 32)
        writeUInt64LE(0x80, into: &image, at: 40)
        writeUInt64LE(0x20, into: &image, at: 48)
        writeUInt64LE(0x40, into: &image, at: 56)
        writeELFHeader(into: &image, at: 64, entry: 0x100000, programHeaderCount: 0)

        let parsed = try ExecutableParser().parse(image)
        XCTAssertEqual(parsed.format, .ps5SELF)
        XCTAssertEqual(parsed.selfHeader?.platform, .ps5)
        XCTAssertEqual(parsed.selfSegments.count, 1)
        XCTAssertTrue(parsed.selfSegments[0].isCompressed)
        XCTAssertTrue(parsed.selfSegments[0].isEncrypted)
    }

    func testLoadsUnencryptedPS5SELFPayloadAtNativeBase() throws {
        var image = Data(repeating: 0, count: 0x200)
        image.replaceSubrange(0..<12, with: SELFHeader.ps5Identifier)
        writeUInt64LE(UInt64(image.count), into: &image, at: 16)
        writeUInt16LE(1, into: &image, at: 24)
        writeUInt16LE(0x52, into: &image, at: 26)
        writeUInt64LE(SELFSegment.blockedFlag, into: &image, at: 32)
        writeUInt64LE(0x180, into: &image, at: 40)
        writeUInt64LE(4, into: &image, at: 48)
        writeUInt64LE(4, into: &image, at: 56)
        writeELFHeader(into: &image, at: 64, entry: 0, programHeaderCount: 1)
        image[72] = 2
        writeUInt32LE(1, into: &image, at: 128)
        writeUInt32LE(5, into: &image, at: 132)
        writeUInt64LE(0x4000, into: &image, at: 136)
        writeUInt64LE(0, into: &image, at: 144)
        writeUInt64LE(0, into: &image, at: 152)
        writeUInt64LE(4, into: &image, at: 160)
        writeUInt64LE(0x1000, into: &image, at: 168)
        writeUInt64LE(0x4000, into: &image, at: 176)
        image.replaceSubrange(0x180..<0x184, with: [0xDE, 0xAD, 0xBE, 0xEF])

        let parsed = try ExecutableParser().parse(image)
        let report = try ExecutableLoader().load(image, image: parsed)
        XCTAssertEqual(report.imageBase, ExecutableLoader.ps5MainImageBase)
        XCTAssertEqual(report.entryPoint, ExecutableLoader.ps5MainImageBase)
        XCTAssertEqual(
            try report.memory.read(at: ExecutableLoader.ps5MainImageBase, length: 4),
            Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
    }

    func testRejectsUnknownExecutable() {
        XCTAssertThrowsError(try ExecutableParser().parse(Data(repeating: 0, count: 128)))
    }

    private func writeELFHeader(
        into data: inout Data,
        at offset: Int,
        entry: UInt64,
        programHeaderCount: UInt16
    ) {
        data.replaceSubrange(offset..<(offset + 6), with: [0x7F, 0x45, 0x4C, 0x46, 2, 1])
        writeUInt16LE(3, into: &data, at: offset + 16)
        writeUInt16LE(0x3E, into: &data, at: offset + 18)
        writeUInt32LE(1, into: &data, at: offset + 20)
        writeUInt64LE(entry, into: &data, at: offset + 24)
        writeUInt64LE(64, into: &data, at: offset + 32)
        writeUInt16LE(64, into: &data, at: offset + 52)
        writeUInt16LE(56, into: &data, at: offset + 54)
        writeUInt16LE(programHeaderCount, into: &data, at: offset + 56)
    }

    private func writeUInt16LE(_ value: UInt16, into data: inout Data, at offset: Int) {
        for index in 0..<2 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private func writeUInt32LE(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private func writeUInt64LE(_ value: UInt64, into data: inout Data, at offset: Int) {
        for index in 0..<8 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
