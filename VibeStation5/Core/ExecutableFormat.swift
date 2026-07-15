// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct ELFHeader: Equatable, Sendable {
    static let size = 64
    static let amd64Machine: UInt16 = 0x3E

    let abi: UInt8
    let abiVersion: UInt8
    let type: UInt16
    let machine: UInt16
    let version: UInt32
    let entryPoint: UInt64
    let programHeaderOffset: UInt64
    let sectionHeaderOffset: UInt64
    let flags: UInt32
    let headerSize: UInt16
    let programHeaderEntrySize: UInt16
    let programHeaderCount: UInt16
    let sectionHeaderEntrySize: UInt16
    let sectionHeaderCount: UInt16
    let sectionHeaderStringIndex: UInt16

    static func parse(from data: Data, at baseOffset: Int) throws -> ELFHeader {
        _ = try data.checkedRange(offset: baseOffset, count: size, context: "ELF header")
        let magic = try data.uint32BE(at: baseOffset, context: "ELF magic")
        guard magic == 0x7F45_4C46 else {
            throw BinaryFormatError.invalid("The executable does not have an ELF signature.")
        }
        guard try data.byte(at: baseOffset + 4, context: "ELF class") == 2 else {
            throw BinaryFormatError.unsupported("Only 64-bit ELF images are supported.")
        }
        guard try data.byte(at: baseOffset + 5, context: "ELF byte order") == 1 else {
            throw BinaryFormatError.unsupported("Only little-endian ELF images are supported.")
        }

        let header = ELFHeader(
            abi: try data.byte(at: baseOffset + 7, context: "ELF ABI"),
            abiVersion: try data.byte(at: baseOffset + 8, context: "ELF ABI version"),
            type: try data.uint16LE(at: baseOffset + 16, context: "ELF type"),
            machine: try data.uint16LE(at: baseOffset + 18, context: "ELF machine"),
            version: try data.uint32LE(at: baseOffset + 20, context: "ELF version"),
            entryPoint: try data.uint64LE(at: baseOffset + 24, context: "ELF entry point"),
            programHeaderOffset: try data.uint64LE(at: baseOffset + 32, context: "ELF program-header offset"),
            sectionHeaderOffset: try data.uint64LE(at: baseOffset + 40, context: "ELF section-header offset"),
            flags: try data.uint32LE(at: baseOffset + 48, context: "ELF flags"),
            headerSize: try data.uint16LE(at: baseOffset + 52, context: "ELF header size"),
            programHeaderEntrySize: try data.uint16LE(at: baseOffset + 54, context: "ELF program-header entry size"),
            programHeaderCount: try data.uint16LE(at: baseOffset + 56, context: "ELF program-header count"),
            sectionHeaderEntrySize: try data.uint16LE(at: baseOffset + 58, context: "ELF section-header entry size"),
            sectionHeaderCount: try data.uint16LE(at: baseOffset + 60, context: "ELF section-header count"),
            sectionHeaderStringIndex: try data.uint16LE(at: baseOffset + 62, context: "ELF section-name index")
        )

        guard header.machine == amd64Machine else {
            throw BinaryFormatError.unsupported(
                "ELF machine \(header.machine) is not the PS5 x86-64 architecture (62)."
            )
        }
        guard header.headerSize >= UInt16(size) else {
            throw BinaryFormatError.invalid("The ELF header size is smaller than the 64-bit ELF header.")
        }
        if header.programHeaderCount > 0, header.programHeaderEntrySize < ProgramHeader.size {
            throw BinaryFormatError.invalid("The ELF program-header entry size is too small.")
        }
        return header
    }
}

struct ProgramHeaderFlags: OptionSet, Equatable, Sendable {
    let rawValue: UInt32

    static let execute = ProgramHeaderFlags(rawValue: 0x1)
    static let write = ProgramHeaderFlags(rawValue: 0x2)
    static let read = ProgramHeaderFlags(rawValue: 0x4)
}

enum ProgramHeaderType: Equatable, Sendable, CustomStringConvertible {
    case null
    case load
    case dynamic
    case tls
    case sceRela
    case sceProcParam
    case sceDynLibData
    case sceRelro
    case unknown(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .null
        case 1: self = .load
        case 2: self = .dynamic
        case 7: self = .tls
        case 0x6000_0000: self = .sceRela
        case 0x6100_0001: self = .sceProcParam
        case 0x6100_0000: self = .sceDynLibData
        case 0x6100_0010: self = .sceRelro
        default: self = .unknown(rawValue)
        }
    }

    var description: String {
        switch self {
        case .null: "NULL"
        case .load: "LOAD"
        case .dynamic: "DYNAMIC"
        case .tls: "TLS"
        case .sceRela: "SCE_RELA"
        case .sceProcParam: "SCE_PROC_PARAM"
        case .sceDynLibData: "SCE_DYNLIB_DATA"
        case .sceRelro: "SCE_RELRO"
        case let .unknown(value): String(format: "0x%08X", value)
        }
    }
}

struct ProgramHeader: Equatable, Sendable {
    static let size: UInt16 = 56

    let rawType: UInt32
    let flags: ProgramHeaderFlags
    let offset: UInt64
    let virtualAddress: UInt64
    let physicalAddress: UInt64
    let fileSize: UInt64
    let memorySize: UInt64
    let alignment: UInt64

    var type: ProgramHeaderType { ProgramHeaderType(rawValue: rawType) }

    static func parse(from data: Data, at offset: Int) throws -> ProgramHeader {
        _ = try data.checkedRange(offset: offset, count: Int(size), context: "ELF program header")
        return ProgramHeader(
            rawType: try data.uint32LE(at: offset, context: "Program-header type"),
            flags: ProgramHeaderFlags(rawValue: try data.uint32LE(at: offset + 4, context: "Program-header flags")),
            offset: try data.uint64LE(at: offset + 8, context: "Program-header file offset"),
            virtualAddress: try data.uint64LE(at: offset + 16, context: "Program-header virtual address"),
            physicalAddress: try data.uint64LE(at: offset + 24, context: "Program-header physical address"),
            fileSize: try data.uint64LE(at: offset + 32, context: "Program-header file size"),
            memorySize: try data.uint64LE(at: offset + 40, context: "Program-header memory size"),
            alignment: try data.uint64LE(at: offset + 48, context: "Program-header alignment")
        )
    }
}

enum SELFPlatform: String, Sendable {
    case ps4 = "PS4"
    case ps5 = "PS5"
}

struct SELFHeader: Equatable, Sendable {
    static let size = 32
    static let segmentSize = 32
    static let ps4Magic: UInt32 = 0x4F15_3D1D
    static let ps5Magic: UInt32 = 0x5414_F5EE
    static let ps4Identifier = Data([0x4F, 0x15, 0x3D, 0x1D, 0x00, 0x01, 0x01, 0x12, 0x01, 0x01, 0x00, 0x00])
    static let ps5Identifier = Data([0x54, 0x14, 0xF5, 0xEE, 0x10, 0x01, 0x01, 0x32, 0x01, 0x03, 0x00, 0x10])

    let platform: SELFPlatform
    let fileSize: UInt64
    let segmentCount: UInt16
    let unknown: UInt16

    var elfOffset: Int {
        Self.size + Int(segmentCount) * Self.segmentSize
    }

    static func parse(from data: Data) throws -> SELFHeader {
        _ = try data.checkedRange(offset: 0, count: size, context: "SELF header")
        let magic = try data.uint32BE(at: 0, context: "SELF magic")
        let platform: SELFPlatform
        let expectedIdentifier: Data
        let expectedUnknown: UInt16
        switch magic {
        case ps4Magic:
            platform = .ps4
            expectedIdentifier = ps4Identifier
            expectedUnknown = 0x22
        case ps5Magic:
            platform = .ps5
            expectedIdentifier = ps5Identifier
            expectedUnknown = 0x52
        default:
            throw BinaryFormatError.invalid("The executable is not a recognized PS4/PS5 SELF image.")
        }

        let identifier = try data.bytes(at: 0, count: 12, context: "SELF identifier")
        let unknown = try data.uint16LE(at: 26, context: "SELF layout identifier")
        guard identifier == expectedIdentifier, unknown == expectedUnknown else {
            throw BinaryFormatError.invalid("The \(platform.rawValue) SELF header signature is not recognized.")
        }

        let header = SELFHeader(
            platform: platform,
            fileSize: try data.uint64LE(at: 16, context: "SELF file size"),
            segmentCount: try data.uint16LE(at: 24, context: "SELF segment count"),
            unknown: unknown
        )
        _ = try data.checkedRange(offset: 0, count: header.elfOffset + ELFHeader.size, context: "SELF tables")
        return header
    }
}

struct SELFSegment: Equatable, Sendable {
    static let blockedFlag: UInt64 = 0x800

    let type: UInt64
    let offset: UInt64
    let compressedSize: UInt64
    let decompressedSize: UInt64

    var isBlocked: Bool { (type & Self.blockedFlag) != 0 }
    var programHeaderID: UInt64 { (type >> 20) & 0xFFF }
    var isEncrypted: Bool { (type & 0x2) != 0 }
    var isCompressed: Bool { (type & 0x8) != 0 }

    static func parse(from data: Data, at offset: Int) throws -> SELFSegment {
        _ = try data.checkedRange(offset: offset, count: SELFHeader.segmentSize, context: "SELF segment")
        return SELFSegment(
            type: try data.uint64LE(at: offset, context: "SELF segment type"),
            offset: try data.uint64LE(at: offset + 8, context: "SELF segment offset"),
            compressedSize: try data.uint64LE(at: offset + 16, context: "SELF compressed size"),
            decompressedSize: try data.uint64LE(at: offset + 24, context: "SELF decompressed size")
        )
    }
}

struct ExecutableImage: Equatable, Sendable {
    let format: ExecutableFormat
    let elfOffset: Int
    let elfHeader: ELFHeader
    let programHeaders: [ProgramHeader]
    let selfHeader: SELFHeader?
    let selfSegments: [SELFSegment]

    var loadableSegments: [ProgramHeader] {
        programHeaders.filter { $0.type == .load }
    }
}

struct ExecutableParser: Sendable {
    func parse(_ data: Data) throws -> ExecutableImage {
        guard data.count >= 4 else {
            throw BinaryFormatError.truncated(context: "Executable", offset: 0, length: 4)
        }

        let magic = try data.uint32BE(at: 0, context: "Executable magic")
        let format: ExecutableFormat
        let selfHeader: SELFHeader?
        let selfSegments: [SELFSegment]
        let elfOffset: Int

        if magic == 0x7F45_4C46 {
            format = .decryptedELF
            selfHeader = nil
            selfSegments = []
            elfOffset = 0
        } else if magic == SELFHeader.ps4Magic || magic == SELFHeader.ps5Magic {
            let header = try SELFHeader.parse(from: data)
            selfHeader = header
            format = header.platform == .ps5 ? .ps5SELF : .ps4SELF
            elfOffset = header.elfOffset
            selfSegments = try (0..<Int(header.segmentCount)).map { index in
                try SELFSegment.parse(
                    from: data,
                    at: SELFHeader.size + index * SELFHeader.segmentSize
                )
            }
        } else {
            throw BinaryFormatError.invalid("The file is neither a decrypted ELF nor a recognized PS4/PS5 SELF image.")
        }

        let elfHeader = try ELFHeader.parse(from: data, at: elfOffset)
        guard elfHeader.programHeaderCount <= 4_096 else {
            throw BinaryFormatError.invalid("The ELF declares too many program headers.")
        }

        guard elfHeader.programHeaderOffset <= UInt64(Int.max) else {
            throw BinaryFormatError.arithmeticOverflow("The program-header table offset cannot be represented on this host.")
        }
        let tableStart = try checkedAdd(elfOffset, Int(elfHeader.programHeaderOffset), "Program-header table")
        let entrySize = Int(elfHeader.programHeaderEntrySize)
        let programHeaders = try (0..<Int(elfHeader.programHeaderCount)).map { index in
            let stride = try checkedMultiply(index, entrySize, "Program-header table")
            let offset = try checkedAdd(tableStart, stride, "Program-header table")
            return try ProgramHeader.parse(from: data, at: offset)
        }

        for header in programHeaders where header.fileSize > header.memorySize && header.type == .load {
            throw BinaryFormatError.invalid("A loadable ELF segment is larger on disk than in memory.")
        }

        return ExecutableImage(
            format: format,
            elfOffset: elfOffset,
            elfHeader: elfHeader,
            programHeaders: programHeaders,
            selfHeader: selfHeader,
            selfSegments: selfSegments
        )
    }

    private func checkedAdd(_ lhs: Int, _ rhs: Int, _ context: String) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw BinaryFormatError.arithmeticOverflow("\(context) offset overflowed.") }
        return value
    }

    private func checkedMultiply(_ lhs: Int, _ rhs: Int, _ context: String) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw BinaryFormatError.arithmeticOverflow("\(context) size overflowed.") }
        return value
    }
}

