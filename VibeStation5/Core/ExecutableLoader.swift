// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct ExecutableLoadReport: Sendable {
    let memory: SparseVirtualMemory
    let loadedBytes: UInt64
    let imageBase: UInt64
    let entryPoint: UInt64
    let appliedRelocationCount: Int
    let importSymbolsByIndex: [Int: String]
}

struct ExecutableLoader: Sendable {
    static let maximumCopiedPayload: UInt64 = 512 * 1_024 * 1_024
    static let ps4MainImageBase: UInt64 = 0x0000_0000_0040_0000
    static let ps5MainImageBase: UInt64 = 0x0000_0008_0000_0000
    static let importedDataRegionSize: UInt64 = 64 * 1_024 * 1_024

    func loadDecryptedELF(_ data: Data, image: ExecutableImage) throws -> ExecutableLoadReport {
        try load(data, image: image)
    }

    func load(_ data: Data, image: ExecutableImage) throws -> ExecutableLoadReport {
        let imageBase = requestedImageBase(for: image)

        var memory = SparseVirtualMemory()
        var loadedBytes: UInt64 = 0
        for (index, segment) in image.programHeaders.enumerated() where segment.type == .load {
            guard segment.memorySize > 0 else { continue }
            var protection: MemoryProtection = []
            if segment.flags.contains(.read) { protection.insert(.read) }
            if segment.flags.contains(.write) { protection.insert(.write) }
            if segment.flags.contains(.execute) { protection.insert(.execute) }

            let (newLoadedBytes, overflow) = loadedBytes.addingReportingOverflow(segment.fileSize)
            guard !overflow, newLoadedBytes <= Self.maximumCopiedPayload else {
                throw BinaryFormatError.unsupported(
                    "The executable has more than 512 MiB of file-backed load data; preparation stopped to protect memory."
                )
            }
            let sourceOffset = try physicalFileOffset(
                for: segment,
                programHeaderIndex: index,
                image: image
            )
            guard sourceOffset <= UInt64(Int.max), segment.fileSize <= UInt64(Int.max) else {
                throw BinaryFormatError.arithmeticOverflow("A loadable segment is too large for this host.")
            }
            _ = try data.checkedRange(
                offset: Int(sourceOffset),
                count: Int(segment.fileSize),
                context: "Executable load segment"
            )

            let (virtualAddress, addressOverflow) = imageBase.addingReportingOverflow(segment.virtualAddress)
            guard !addressOverflow else {
                throw BinaryFormatError.arithmeticOverflow("A loadable segment virtual address overflowed.")
            }
            try memory.mapFileBacked(
                baseAddress: virtualAddress,
                memorySize: segment.memorySize,
                protection: protection,
                label: "\(image.format.rawValue) LOAD \(index)",
                data: data,
                sourceOffset: Int(sourceOffset),
                fileSize: Int(segment.fileSize)
            )
            loadedBytes = newLoadedBytes
        }

        let relocationCount = try applyBaseRelocations(
            image: image,
            imageBase: imageBase,
            memory: &memory
        )
        let importSymbols = try loadImportSymbols(
            image: image,
            imageBase: imageBase,
            memory: memory
        )

        let (entryPoint, entryOverflow) = imageBase.addingReportingOverflow(image.elfHeader.entryPoint)
        guard !entryOverflow else {
            throw BinaryFormatError.arithmeticOverflow("The executable entry point overflowed.")
        }
        return ExecutableLoadReport(
            memory: memory,
            loadedBytes: loadedBytes,
            imageBase: imageBase,
            entryPoint: entryPoint,
            appliedRelocationCount: relocationCount,
            importSymbolsByIndex: importSymbols
        )
    }

    private func requestedImageBase(for image: ExecutableImage) -> UInt64 {
        let minimumAddress = image.loadableSegments.map(\.virtualAddress).min() ?? 0
        guard minimumAddress < 0x1_0000 else { return 0 }
        let isPS5 = image.elfHeader.abiVersion == 2 || image.selfHeader?.platform == .ps5
        return isPS5 ? Self.ps5MainImageBase : Self.ps4MainImageBase
    }

    private func physicalFileOffset(
        for segment: ProgramHeader,
        programHeaderIndex: Int,
        image: ExecutableImage
    ) throws -> UInt64 {
        guard image.selfHeader != nil else {
            let (offset, overflow) = UInt64(image.elfOffset).addingReportingOverflow(segment.offset)
            guard !overflow else {
                throw BinaryFormatError.arithmeticOverflow("The ELF segment file offset overflowed.")
            }
            return offset
        }

        if let selfSegment = image.selfSegments.first(where: {
            $0.isBlocked && $0.programHeaderID == UInt64(programHeaderIndex)
        }) {
            if selfSegment.isEncrypted {
                throw BinaryFormatError.unsupported(
                    "SELF program header \(programHeaderIndex) is encrypted and needs a dumped/decrypted payload."
                )
            }
            if selfSegment.isCompressed {
                throw BinaryFormatError.unsupported(
                    "SELF program header \(programHeaderIndex) is compressed and needs decompression before execution."
                )
            }
            return selfSegment.offset
        }

        let (fallback, overflow) = UInt64(image.elfOffset).addingReportingOverflow(segment.offset)
        guard !overflow else {
            throw BinaryFormatError.arithmeticOverflow("The SELF segment fallback offset overflowed.")
        }
        return fallback
    }

    private func applyBaseRelocations(
        image: ExecutableImage,
        imageBase: UInt64,
        memory: inout SparseVirtualMemory
    ) throws -> Int {
        guard let dynamicHeader = image.programHeaders.first(where: { $0.type == .dynamic }),
              dynamicHeader.fileSize > 0,
              dynamicHeader.fileSize <= UInt64(Int.max) else {
            return 0
        }
        let (dynamicAddress, addressOverflow) = imageBase.addingReportingOverflow(dynamicHeader.virtualAddress)
        guard !addressOverflow else {
            throw BinaryFormatError.arithmeticOverflow("The dynamic-table address overflowed.")
        }
        let dynamicTable = try memory.readIgnoringProtection(
            at: dynamicAddress,
            length: Int(dynamicHeader.fileSize)
        )

        var relaOffset: UInt64 = 0
        var relaSize: UInt64 = 0
        var jumpRelocationOffset: UInt64 = 0
        var jumpRelocationSize: UInt64 = 0
        var cursor = 0
        while cursor + 16 <= dynamicTable.count {
            let tag = try dynamicTable.uint64LE(at: cursor, context: "Dynamic tag")
            let value = try dynamicTable.uint64LE(at: cursor + 8, context: "Dynamic value")
            if tag == 0 { break }
            switch tag {
            case 0x07 where relaOffset == 0, 0x6100_002F:
                relaOffset = value
            case 0x08 where relaSize == 0, 0x6100_0031:
                relaSize = value
            case 0x17 where jumpRelocationOffset == 0, 0x6100_0029:
                jumpRelocationOffset = value
            case 0x02 where jumpRelocationSize == 0, 0x6100_002D:
                jumpRelocationSize = value
            default:
                break
            }
            cursor += 16
        }

        var applied = 0
        var importedDataSlots: [UInt32: UInt64] = [:]
        var importedDataRegionMapped = false
        let importedDataBase = imageBase &+ 0x1_0000_0000
        if relaSize > 0 {
            applied += try applyBaseRelocationTable(
                offset: relaOffset,
                size: relaSize,
                imageBase: imageBase,
                memory: &memory,
                importedDataBase: importedDataBase,
                importedDataSlots: &importedDataSlots,
                importedDataRegionMapped: &importedDataRegionMapped
            )
        }
        if jumpRelocationSize > 0 {
            applied += try applyBaseRelocationTable(
                offset: jumpRelocationOffset,
                size: jumpRelocationSize,
                imageBase: imageBase,
                memory: &memory,
                importedDataBase: importedDataBase,
                importedDataSlots: &importedDataSlots,
                importedDataRegionMapped: &importedDataRegionMapped
            )
        }
        return applied
    }

    private func loadImportSymbols(
        image: ExecutableImage,
        imageBase: UInt64,
        memory: SparseVirtualMemory
    ) throws -> [Int: String] {
        guard let dynamicHeader = image.programHeaders.first(where: { $0.type == .dynamic }),
              dynamicHeader.fileSize > 0,
              dynamicHeader.fileSize <= UInt64(Int.max) else {
            return [:]
        }
        let dynamicTable = try memory.readIgnoringProtection(
            at: imageBase &+ dynamicHeader.virtualAddress,
            length: Int(dynamicHeader.fileSize)
        )

        var stringTableOffset: UInt64 = 0
        var stringTableSize: UInt64 = 0
        var symbolTableOffset: UInt64 = 0
        var symbolTableSize: UInt64 = 0
        var jumpRelocationOffset: UInt64 = 0
        var jumpRelocationSize: UInt64 = 0
        var cursor = 0
        while cursor + 16 <= dynamicTable.count {
            let tag = try dynamicTable.uint64LE(at: cursor, context: "Dynamic tag")
            let value = try dynamicTable.uint64LE(at: cursor + 8, context: "Dynamic value")
            if tag == 0 { break }
            switch tag {
            case 0x05 where stringTableOffset == 0, 0x6100_0035: stringTableOffset = value
            case 0x0A where stringTableSize == 0, 0x6100_0037: stringTableSize = value
            case 0x06 where symbolTableOffset == 0, 0x6100_0039: symbolTableOffset = value
            case 0x6100_003F: symbolTableSize = value
            case 0x17 where jumpRelocationOffset == 0, 0x6100_0029: jumpRelocationOffset = value
            case 0x02 where jumpRelocationSize == 0, 0x6100_002D: jumpRelocationSize = value
            default: break
            }
            cursor += 16
        }
        guard stringTableSize > 0, symbolTableSize > 0, jumpRelocationSize > 0,
              stringTableSize <= UInt64(Int.max), symbolTableSize <= UInt64(Int.max),
              jumpRelocationSize <= UInt64(Int.max) else {
            return [:]
        }

        let stringTable = try memory.readIgnoringProtection(
            at: imageBase &+ stringTableOffset,
            length: Int(stringTableSize)
        )
        let symbolTable = try memory.readIgnoringProtection(
            at: imageBase &+ symbolTableOffset,
            length: Int(symbolTableSize)
        )
        let relocations = try memory.readIgnoringProtection(
            at: imageBase &+ jumpRelocationOffset,
            length: Int(jumpRelocationSize)
        )

        var symbols: [Int: String] = [:]
        cursor = 0
        var importIndex = 0
        while cursor + 24 <= relocations.count {
            let info = try relocations.uint64LE(at: cursor + 8, context: "Jump relocation info")
            let symbolIndex = Int(info >> 32)
            let symbolOffset = symbolIndex * 24
            if symbolOffset >= 0, symbolOffset + 24 <= symbolTable.count {
                let nameOffset = Int(try symbolTable.uint32LE(at: symbolOffset, context: "Symbol name"))
                if nameOffset >= 0, nameOffset < stringTable.count {
                    let tail = stringTable[nameOffset...]
                    if let end = tail.firstIndex(of: 0) {
                        let rawName = String(decoding: tail[..<end], as: UTF8.self)
                        symbols[importIndex] = rawName.split(separator: "#", maxSplits: 1).first.map(String.init) ?? rawName
                    }
                }
            }
            cursor += 24
            importIndex += 1
        }
        return symbols
    }

    private func applyBaseRelocationTable(
        offset: UInt64,
        size: UInt64,
        imageBase: UInt64,
        memory: inout SparseVirtualMemory,
        importedDataBase: UInt64,
        importedDataSlots: inout [UInt32: UInt64],
        importedDataRegionMapped: inout Bool
    ) throws -> Int {
        guard size > 0, size <= UInt64(Int.max) else { return 0 }
        let (tableAddress, tableOverflow) = imageBase.addingReportingOverflow(offset)
        guard !tableOverflow else {
            throw BinaryFormatError.arithmeticOverflow("A relocation-table address overflowed.")
        }
        let table = try memory.readIgnoringProtection(at: tableAddress, length: Int(size))
        var applied = 0
        var cursor = 0
        while cursor + 24 <= table.count {
            let relocationOffset = try table.uint64LE(at: cursor, context: "Relocation offset")
            let relocationInfo = try table.uint64LE(at: cursor + 8, context: "Relocation info")
            let addendBits = try table.uint64LE(at: cursor + 16, context: "Relocation addend")
            let relocationType = UInt32(truncatingIfNeeded: relocationInfo)
            let symbolIndex = UInt32(truncatingIfNeeded: relocationInfo >> 32)
            let value: UInt64?
            switch relocationType {
            case 8:
                value = imageBase &+ addendBits
            case 16:
                value = 1
            case 6:
                if !importedDataRegionMapped {
                    try memory.map(
                        baseAddress: importedDataBase,
                        size: Self.importedDataRegionSize,
                        protection: [.read, .write],
                        label: "Imported data objects"
                    )
                    importedDataRegionMapped = true
                }
                if let existing = importedDataSlots[symbolIndex] {
                    value = existing
                } else {
                    let slot = importedDataBase &+ UInt64(importedDataSlots.count * 64)
                    importedDataSlots[symbolIndex] = slot
                    value = slot
                }
            default:
                value = nil
            }

            if let value {
                let (target, targetOverflow) = imageBase.addingReportingOverflow(relocationOffset)
                guard !targetOverflow else {
                    throw BinaryFormatError.arithmeticOverflow("A relocation target address overflowed.")
                }
                var bytes = Data(count: 8)
                for index in 0..<8 {
                    bytes[index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
                }
                try memory.write(bytes, at: target, bypassProtection: true)
                applied += 1
            }
            cursor += 24
        }
        return applied
    }
}
