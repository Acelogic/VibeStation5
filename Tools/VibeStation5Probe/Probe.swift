// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation

@main
struct VibeStation5Probe {
    static func main() {
        let arguments = CommandLine.arguments
        let isDisassembly = arguments.count >= 4 && arguments[2] == "--disassemble"
        let isImportLookup = arguments.count == 4 && arguments[2] == "--import-index"
        let isCallXref = arguments.count == 4 && arguments[2] == "--call-xrefs"
        guard arguments.count == 2 || arguments.count == 3 || isDisassembly ||
                isImportLookup || isCallXref else {
            print("Usage: VibeStation5Probe <path-to-eboot.bin> [instruction-budget]")
            print("       VibeStation5Probe <path-to-eboot.bin> --disassemble <address> [count]")
            print("       VibeStation5Probe <path-to-eboot.bin> --import-index <index>")
            print("       VibeStation5Probe <path-to-eboot.bin> --call-xrefs <address>")
            exit(64)
        }

        let path = arguments[1]
        let instructionBudget = arguments.count == 3 && !isDisassembly
            ? max(Int(arguments[2]) ?? 1_000_000, 1)
            : 1_000_000
        let disassemblyAddress: UInt64? = isDisassembly ? parseInteger(arguments[3]) : nil
        let disassemblyCount = isDisassembly && arguments.count >= 5
            ? max(Int(arguments[4]) ?? 256, 1)
            : 256
        let importLookupIndex = isImportLookup ? parseInteger(arguments[3]).map(Int.init) : nil
        let callXrefTarget = isCallXref ? parseInteger(arguments[3]) : nil
        if isDisassembly, disassemblyAddress == nil {
            print("ERROR=Invalid disassembly address: \(arguments[3])")
            exit(64)
        }
        if isImportLookup, importLookupIndex == nil {
            print("ERROR=Invalid import index: \(arguments[3])")
            exit(64)
        }
        if isCallXref, callXrefTarget == nil {
            print("ERROR=Invalid call target address: \(arguments[3])")
            exit(64)
        }
        let url = URL(fileURLWithPath: path)
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            print("BOOT_ATTEMPT=begin")
            print("EXECUTABLE=\(path)")
            print("FILE_SIZE=\(values.fileSize ?? data.count)")

            let image = try ExecutableParser().parse(data)
            let encrypted = image.selfSegments.filter(\.isEncrypted).count
            let compressed = image.selfSegments.filter(\.isCompressed).count
            print("FORMAT=\(image.format.rawValue)")
            print("ELF_ENTRY_POINT=\(image.elfHeader.entryPoint.hexadecimal)")
            print("PROGRAM_HEADERS=\(image.programHeaders.count)")
            print("LOAD_SEGMENTS=\(image.loadableSegments.count)")
            print("SELF_SEGMENTS=\(image.selfSegments.count)")
            print("ENCRYPTED_SEGMENTS=\(encrypted)")
            print("COMPRESSED_SEGMENTS=\(compressed)")

            let loadReport = try ExecutableLoader().load(data, image: image)
            print("IMAGE_LOAD=ready")
            print("IMAGE_BASE=\(loadReport.imageBase.hexadecimal)")
            print("ENTRY_POINT=\(loadReport.entryPoint.hexadecimal)")
            print("RESERVED_MEMORY=\(loadReport.memory.reservedByteCount)")
            print("FILE_BACKED_BYTES=\(loadReport.loadedBytes)")
            print("APPLIED_RELOCATIONS=\(loadReport.appliedRelocationCount)")
            print("DIRTY_RESIDENT_MEMORY=\(loadReport.memory.residentByteCount)")

            var memory = loadReport.memory
            if let importLookupIndex {
                let symbol = loadReport.importSymbolsByIndex[importLookupIndex] ?? "<unknown>"
                print("IMPORT_INDEX=\(importLookupIndex)")
                print("IMPORT_SYMBOL=\(symbol)")
                exit(0)
            }
            if let callXrefTarget {
                for region in memory.regions where region.protection.contains(.execute) {
                    guard region.size <= UInt64(Int.max),
                          let bytes = try? memory.read(
                            at: region.baseAddress,
                            length: Int(region.size)
                          )
                    else { continue }
                    for offset in 0..<(max(bytes.count - 4, 0)) where bytes[offset] == 0xE8 {
                        var rawDisplacement: UInt32 = 0
                        for byte in 0..<4 {
                            rawDisplacement |= UInt32(bytes[offset + 1 + byte]) << UInt32(byte * 8)
                        }
                        let nextAddress = region.baseAddress + UInt64(offset) + 5
                        let displacement = Int64(Int32(bitPattern: rawDisplacement))
                        let destination = UInt64(bitPattern: Int64(bitPattern: nextAddress) + displacement)
                        if destination == callXrefTarget {
                            print("CALL_XREF=\((region.baseAddress + UInt64(offset)).hexadecimal)")
                        }
                    }
                }
                exit(0)
            }
            if let disassemblyAddress {
                let decoder = try X86Decoder()
                var cursor = disassemblyAddress
                for _ in 0..<disassemblyCount {
                    let instruction = try decoder.decode(memory: memory, at: cursor)
                    print("DISASSEMBLY=\(instruction.address.hexadecimal): \(instruction.text)")
                    cursor = instruction.nextAddress
                }
                exit(0)
            }
            let execution = try ARMNativeX86Interpreter(
                gameRootURL: url.deletingLastPathComponent()
            ).run(
                memory: &memory,
                entryPoint: loadReport.entryPoint,
                importSymbolsByIndex: loadReport.importSymbolsByIndex,
                instructionBudget: instructionBudget
            )
#if arch(arm64)
            print("CPU_BACKEND=arm64-native-swift-interpreter")
#else
            print("CPU_BACKEND=portable-swift-interpreter")
#endif
            print("EXECUTED_INSTRUCTIONS=\(execution.instructionCount)")
            print("INTERCEPTED_IMPORTS=\(execution.interceptedImportCount)")
            print("GUEST_THREADS=\(execution.guestThreadCount)")
            print("CONTEXT_SWITCHES=\(execution.contextSwitchCount)")
            for thread in execution.guestThreads {
                print(
                    "GUEST_THREAD=handle=\(thread.handle.hexadecimal) " +
                    "status=\(thread.status) instructions=\(thread.instructionCount) " +
                    "entry=\(thread.entryPoint.hexadecimal) rip=\(thread.instructionPointer.hexadecimal)"
                )
            }
            for hotspot in execution.guestHotspots {
                print(
                    "GUEST_HOTSPOT=handle=\(hotspot.threadHandle.hexadecimal) " +
                    "rip=\(hotspot.instructionPointer.hexadecimal) samples=\(hotspot.samples)"
                )
            }
            print("FINAL_RIP=\(execution.finalInstructionPointer.hexadecimal)")
            print("STOP_REASON=\(execution.reason.text)")
            if let frame = execution.videoFrame {
                print(
                    "VIDEO_FRAME=\(frame.width)x\(frame.height) " +
                        "stride=\(frame.bytesPerRow) buffer=\(frame.bufferIndex) " +
                        "flip=\(frame.flipCount) address=\(frame.sourceAddress.hexadecimal) " +
                        "format=\(frame.pixelFormat.hexadecimal) " +
                        "nonzero=\(frame.nonzeroByteCount)"
                )
            }
            for (register, value) in execution.finalRegisters.sorted(by: { $0.key < $1.key }) {
                print("REGISTER=\(register) \(value.hexadecimal)")
                if value != 0,
                   let region = memory.regions.first(where: {
                       value >= $0.baseAddress && value < $0.endAddress
                   }) {
                    let available = min(UInt64(64), region.endAddress - value)
                    if let bytes = try? memory.readIgnoringProtection(
                        at: value,
                        length: Int(available)
                    ) {
                        print("MEMORY=\(register) \(bytes.map { String(format: "%02X", $0) }.joined())")
                    }
                }
            }
            if var frame = execution.finalRegisters["rbp"] {
                for depth in 0..<16 {
                    guard frame != 0,
                          let bytes = try? memory.readIgnoringProtection(at: frame, length: 64),
                          bytes.count >= 16 else { break }
                    func qword(at offset: Int) -> UInt64 {
                        var value: UInt64 = 0
                        for index in 0..<8 {
                            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
                        }
                        return value
                    }
                    let parent = qword(at: 0)
                    let returnAddress = qword(at: 8)
                    print(
                        "GUEST_FRAME=depth=\(depth) rbp=\(frame.hexadecimal) " +
                        "parent=\(parent.hexadecimal) return=\(returnAddress.hexadecimal)"
                    )
                    print(
                        "GUEST_FRAME_MEMORY=depth=\(depth) " +
                        bytes.map { String(format: "%02X", $0) }.joined()
                    )
                    guard parent > frame, parent - frame <= 16 * 1_024 * 1_024 else { break }
                    frame = parent
                }
            }
            for (symbol, count) in execution.importCounts.sorted(by: {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }) {
                print("IMPORT_COUNT=\(count) \(symbol)")
            }
            for event in execution.runtimeEvents {
                print("RUNTIME_EVENT=\(event)")
            }
            for line in execution.recentImports {
                print("IMPORT=\(line)")
            }
            for line in execution.recentInstructions {
                print("TRACE=\(line)")
            }
            if let decoder = try? X86Decoder() {
                var cursor = execution.finalInstructionPointer
                for _ in 0..<24 {
                    guard let instruction = try? decoder.decode(memory: memory, at: cursor) else { break }
                    print("LOOKAHEAD=\(instruction.address.hexadecimal): \(instruction.text)")
                    cursor = instruction.nextAddress
                }
            }

            if execution.reason == .sentinelReturn {
                print("BOOT_RESULT=guest-returned")
                exit(0)
            }
            print("BOOT_RESULT=stopped")
            exit(2)
        } catch {
            print("BOOT_ATTEMPT=failed")
            print("ERROR=\(error.localizedDescription)")
            print("BOOT_RESULT=not-booted")
            exit(1)
        }
    }

    private static func parseInteger(_ text: String) -> UInt64? {
        if text.lowercased().hasPrefix("0x") {
            return UInt64(text.dropFirst(2), radix: 16)
        }
        return UInt64(text)
    }
}
