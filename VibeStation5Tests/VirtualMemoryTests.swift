// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import VibeStation5

final class VirtualMemoryTests: XCTestCase {
    func testSparsePagesAreZeroInitializedAndWritable() throws {
        var memory = SparseVirtualMemory()
        try memory.map(
            baseAddress: 0x1000,
            size: 0x3000,
            protection: [.read, .write],
            label: "test"
        )

        XCTAssertEqual(try memory.read(at: 0x1FFE, length: 4), Data(repeating: 0, count: 4))
        try memory.write(Data([1, 2, 3, 4]), at: 0x1FFE)
        XCTAssertEqual(try memory.read(at: 0x1FFE, length: 4), Data([1, 2, 3, 4]))
        XCTAssertEqual(memory.residentByteCount, 0x2000)
    }

    func testWriteProtectionIsEnforced() throws {
        var memory = SparseVirtualMemory()
        try memory.map(baseAddress: 0x8000, size: 0x1000, protection: .read, label: "ro")
        XCTAssertThrowsError(try memory.write(Data([1]), at: 0x8000))
        XCTAssertNoThrow(try memory.write(Data([1]), at: 0x8000, bypassProtection: true))
    }

    func testOverlappingMappingsAreRejected() throws {
        var memory = SparseVirtualMemory()
        try memory.map(baseAddress: 0x1000, size: 0x2000, protection: .read, label: "first")
        XCTAssertThrowsError(
            try memory.map(baseAddress: 0x2000, size: 0x1000, protection: .read, label: "overlap")
        )
    }

    func testFileBackedMappingStaysLazyUntilWritten() throws {
        var memory = SparseVirtualMemory()
        let source = Data([0x10, 0x20, 0x30, 0x40])
        try memory.mapFileBacked(
            baseAddress: 0xA000,
            memorySize: 0x1000,
            protection: [.read, .write],
            label: "file",
            data: source,
            sourceOffset: 0,
            fileSize: source.count
        )

        XCTAssertEqual(memory.residentByteCount, 0)
        XCTAssertEqual(try memory.read(at: 0xA000, length: 6), Data([0x10, 0x20, 0x30, 0x40, 0, 0]))
        try memory.write(Data([0xFF]), at: 0xA001)
        XCTAssertEqual(memory.residentByteCount, 0x1000)
        XCTAssertEqual(try memory.read(at: 0xA000, length: 4), Data([0x10, 0xFF, 0x30, 0x40]))
    }

    func testARMNativeInterpreterReturnsThroughSentinel() throws {
        var memory = SparseVirtualMemory()
        try memory.map(
            baseAddress: 0x0040_0000,
            size: 0x1000,
            protection: [.read, .execute],
            label: "guest code"
        )
        try memory.write(
            Data([0xB8, 0x2A, 0, 0, 0, 0xC3]),
            at: 0x0040_0000,
            bypassProtection: true
        )

        let result = try ARMNativeX86Interpreter().run(
            memory: &memory,
            entryPoint: 0x0040_0000,
            instructionBudget: 10
        )
        XCTAssertEqual(result.reason, .sentinelReturn)
        XCTAssertEqual(result.instructionCount, 2)
    }

    func testARMNativeInterpreterProvidesInitialThreadLocalStorage() throws {
        var memory = SparseVirtualMemory()
        try memory.map(
            baseAddress: 0x0040_0000,
            size: 0x1000,
            protection: [.read, .execute],
            label: "guest code"
        )
        try memory.write(
            Data([
                0x64, 0x48, 0x8B, 0x04, 0x25, 0, 0, 0, 0, // mov rax, fs:[0]
                0x48, 0x85, 0xC0,                         // test rax, rax
                0x75, 0x02,                               // jne return
                0x0F, 0x0B,                               // ud2
                0xC3,                                     // return: ret
            ]),
            at: 0x0040_0000,
            bypassProtection: true
        )

        let result = try ARMNativeX86Interpreter().run(
            memory: &memory,
            entryPoint: 0x0040_0000,
            instructionBudget: 10
        )
        XCTAssertEqual(result.reason, .sentinelReturn)
    }

    func testARMNativeInterpreterProvidesDeterministicCPUIDFeatures() throws {
        let codeBase: UInt64 = 0x0040_0000
        let outputAddress = codeBase + 0x800
        var memory = SparseVirtualMemory()
        try memory.map(
            baseAddress: codeBase,
            size: 0x1000,
            protection: [.read, .write, .execute],
            label: "guest code and CPUID output"
        )
        try memory.write(
            Data([
                0xB8, 0x01, 0, 0, 0x80,             // mov eax, 0x80000001
                0x31, 0xC9,                         // xor ecx, ecx
                0x0F, 0xA2,                         // cpuid
                0x89, 0x0C, 0x25, 0, 0x08, 0x40, 0, // mov [0x400800], ecx
                0xC3,                               // ret
            ]),
            at: codeBase
        )

        let result = try ARMNativeX86Interpreter().run(
            memory: &memory,
            entryPoint: codeBase,
            instructionBudget: 10
        )

        XCTAssertEqual(result.reason, .sentinelReturn)
        XCTAssertEqual(try memory.read(at: outputAddress, length: 4), Data([0x21, 0, 0, 0]))
    }

    func testARMNativeInterpreterExecutesBMIAndNot() throws {
        let codeBase: UInt64 = 0x0040_0000
        var code = Data([0x48, 0xBE]) // mov rsi, 0x0f0f
        appendUInt64(0x0F0F, to: &code)
        code.append(contentsOf: [0x49, 0xBD]) // mov r13, 0xffff
        appendUInt64(0xFFFF, to: &code)
        code.append(contentsOf: [0xC4, 0xC2, 0xC8, 0xF2, 0xF5]) // andn rsi, rsi, r13
        code.append(contentsOf: [0x48, 0x89, 0xF0, 0xC3]) // mov rax, rsi; ret

        var memory = SparseVirtualMemory()
        try memory.map(
            baseAddress: codeBase,
            size: 0x1000,
            protection: [.read, .write, .execute],
            label: "guest BMI code"
        )
        try memory.write(code, at: codeBase)

        let result = try ARMNativeX86Interpreter().run(
            memory: &memory,
            entryPoint: codeBase,
            instructionBudget: 10
        )

        XCTAssertEqual(result.reason, .sentinelReturn)
        XCTAssertEqual(result.finalRegisters["rax"], 0xF0F0)
    }

    func testARMNativeInterpreterUsesLow64BitsOfXMMShiftCount() throws {
        let codeBase: UInt64 = 0x0040_0000
        let countAddress = codeBase + 0x4D0
        let code = Data([
            0xBD, 0x00, 0x08, 0x40, 0x00,             // mov ebp, 0x400800
            0xB8, 0x01, 0x00, 0x00, 0x00,             // mov eax, 1
            0xC5, 0xF9, 0x6E, 0xC0,                   // vmovd xmm0, eax
            0xC5, 0xF9, 0xF2, 0x85, 0xD0, 0xFC, 0xFF, 0xFF, // vpslld xmm0, xmm0, [rbp-0x330]
            0xC5, 0xF9, 0x7E, 0xC0,                   // vmovd eax, xmm0
            0xC3,
        ])

        var memory = SparseVirtualMemory()
        try memory.map(
            baseAddress: codeBase,
            size: 0x1000,
            protection: [.read, .write, .execute],
            label: "guest packed shift code"
        )
        try memory.write(code, at: codeBase)
        try memory.write(
            Data([4, 0, 0, 0, 0, 0, 0, 0] + Array(repeating: 0xFF, count: 8)),
            at: countAddress
        )

        let result = try ARMNativeX86Interpreter().run(
            memory: &memory,
            entryPoint: codeBase,
            instructionBudget: 10
        )

        XCTAssertEqual(result.reason, .sentinelReturn)
        XCTAssertEqual(result.finalRegisters["rax"], 16)
    }

    func testARMNativeInterpreterMultipliesPackedDWords() throws {
        let codeBase: UInt64 = 0x0040_0000
        let code = Data([
            0xB8, 0x02, 0x00, 0x00, 0x00,       // mov eax, 2
            0xC5, 0xF9, 0x6E, 0xC0,             // vmovd xmm0, eax
            0xB8, 0x03, 0x00, 0x00, 0x00,       // mov eax, 3
            0xC5, 0xF9, 0x6E, 0xC8,             // vmovd xmm1, eax
            0xC4, 0xE2, 0x79, 0x40, 0xC1,       // vpmulld xmm0, xmm0, xmm1
            0xC5, 0xF9, 0x7E, 0xC0,             // vmovd eax, xmm0
            0xC3,
        ])

        var memory = SparseVirtualMemory()
        try memory.map(
            baseAddress: codeBase,
            size: 0x1000,
            protection: [.read, .write, .execute],
            label: "guest packed multiply code"
        )
        try memory.write(code, at: codeBase)
        let result = try ARMNativeX86Interpreter().run(
            memory: &memory,
            entryPoint: codeBase,
            instructionBudget: 10
        )

        XCTAssertEqual(result.reason, .sentinelReturn)
        XCTAssertEqual(result.finalRegisters["rax"], 6)
    }

    func testARMNativeInterpreterRunsCreatedGuestThreadBeforeJoin() throws {
        let codeBase: UInt64 = 0x0040_0000
        let createStub: UInt64 = codeBase + 0x100
        let joinStub: UInt64 = codeBase + 0x120
        let threadEntry: UInt64 = codeBase + 0x200
        let threadHandle: UInt64 = codeBase + 0x300
        let threadResult: UInt64 = codeBase + 0x308

        var code = Data()
        code.append(contentsOf: [0x48, 0xBF]) // mov rdi, threadHandle
        appendUInt64(threadHandle, to: &code)
        code.append(contentsOf: [0x31, 0xF6]) // xor esi, esi
        code.append(contentsOf: [0x48, 0xBA]) // mov rdx, threadEntry
        appendUInt64(threadEntry, to: &code)
        code.append(contentsOf: [0xB9, 0x2A, 0, 0, 0]) // mov ecx, 42
        code.append(contentsOf: [0x45, 0x31, 0xC0]) // xor r8d, r8d
        appendRelativeCall(to: createStub, codeBase: codeBase, code: &code)
        code.append(contentsOf: [0x48, 0x8B, 0x3C, 0x25]) // mov rdi, [threadHandle]
        appendUInt32(UInt32(threadHandle), to: &code)
        code.append(contentsOf: [0x48, 0xBE]) // mov rsi, threadResult
        appendUInt64(threadResult, to: &code)
        appendRelativeCall(to: joinStub, codeBase: codeBase, code: &code)
        code.append(0xC3)

        var memory = SparseVirtualMemory()
        try memory.map(
            baseAddress: codeBase,
            size: 0x1000,
            protection: [.read, .write, .execute],
            label: "guest code and scheduler state"
        )
        try memory.write(code, at: codeBase)
        try memory.write(importStub(index: 1), at: createStub)
        try memory.write(importStub(index: 2), at: joinStub)
        try memory.write(Data([0x89, 0xF8, 0xC3]), at: threadEntry) // mov eax, edi; ret

        let result = try ARMNativeX86Interpreter().run(
            memory: &memory,
            entryPoint: codeBase,
            importSymbolsByIndex: [
                1: "6UgtwV+0zb4",
                2: "onNY9Byn-W8",
            ],
            instructionBudget: 100
        )

        XCTAssertEqual(result.reason, .sentinelReturn)
        XCTAssertEqual(result.interceptedImportCount, 2)
        XCTAssertNotEqual(try readUInt64(from: memory, at: threadHandle), 0)
        XCTAssertEqual(try readUInt64(from: memory, at: threadResult), 42)
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        for index in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> UInt32(index * 8))) }
    }

    private func appendUInt64(_ value: UInt64, to data: inout Data) {
        for index in 0..<8 { data.append(UInt8(truncatingIfNeeded: value >> UInt64(index * 8))) }
    }

    private func appendRelativeCall(to target: UInt64, codeBase: UInt64, code: inout Data) {
        let nextInstruction = codeBase + UInt64(code.count) + 5
        let displacement = Int32(truncatingIfNeeded: Int64(target) - Int64(nextInstruction))
        code.append(0xE8)
        appendUInt32(UInt32(bitPattern: displacement), to: &code)
    }

    private func importStub(index: UInt32) -> Data {
        var data = Data([0xFF, 0x25, 0, 0, 0, 0, 0x68])
        appendUInt32(index, to: &data)
        data.append(contentsOf: [0xE9, 0, 0, 0, 0])
        return data
    }

    private func readUInt64(from memory: SparseVirtualMemory, at address: UInt64) throws -> UInt64 {
        let bytes = try memory.read(at: address, length: 8)
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[index]) << UInt64(index * 8) }
        return value
    }
}
