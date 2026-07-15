// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct MemoryProtection: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let read = MemoryProtection(rawValue: 1 << 0)
    static let write = MemoryProtection(rawValue: 1 << 1)
    static let execute = MemoryProtection(rawValue: 1 << 2)

    var text: String {
        "\(contains(.read) ? "r" : "-")\(contains(.write) ? "w" : "-")\(contains(.execute) ? "x" : "-")"
    }
}

struct VirtualMemoryRegion: Equatable, Sendable {
    let baseAddress: UInt64
    let size: UInt64
    let protection: MemoryProtection
    let label: String

    var endAddress: UInt64 { baseAddress + size }
}

enum VirtualMemoryError: Error, Equatable, LocalizedError {
    case zeroSize
    case overflow
    case overlap
    case unmapped(address: UInt64, length: Int)
    case protection(address: UInt64, required: MemoryProtection)

    var errorDescription: String? {
        switch self {
        case .zeroSize:
            "A virtual-memory mapping cannot have zero size."
        case .overflow:
            "A virtual-memory address range overflowed."
        case .overlap:
            "The virtual-memory mapping overlaps an existing region."
        case let .unmapped(address, length):
            "Virtual range \(address.hexadecimal) + \(length) is not mapped."
        case let .protection(address, required):
            "Virtual address \(address.hexadecimal) does not permit \(required.text) access."
        }
    }
}

struct SparseVirtualMemory: Sendable {
    static let pageSize: UInt64 = 0x1000

    private struct FileBacking: Sendable {
        let baseAddress: UInt64
        let length: UInt64
        let data: Data
        let sourceOffset: Int

        var endAddress: UInt64 { baseAddress + length }
    }

    private(set) var regions: [VirtualMemoryRegion] = []
    private var pages: [UInt64: [UInt8]] = [:]
    private var fileBackings: [FileBacking] = []

    var reservedByteCount: UInt64 {
        regions.reduce(0) { partial, region in
            let (value, overflow) = partial.addingReportingOverflow(region.size)
            return overflow ? UInt64.max : value
        }
    }

    var residentByteCount: UInt64 {
        UInt64(pages.count) * Self.pageSize
    }

    mutating func map(
        baseAddress: UInt64,
        size: UInt64,
        protection: MemoryProtection,
        label: String
    ) throws {
        guard size > 0 else { throw VirtualMemoryError.zeroSize }
        let (endAddress, overflow) = baseAddress.addingReportingOverflow(size)
        guard !overflow else { throw VirtualMemoryError.overflow }
        guard !regions.contains(where: { baseAddress < $0.endAddress && endAddress > $0.baseAddress }) else {
            throw VirtualMemoryError.overlap
        }

        regions.append(VirtualMemoryRegion(
            baseAddress: baseAddress,
            size: size,
            protection: protection,
            label: label
        ))
        regions.sort { $0.baseAddress < $1.baseAddress }
    }

    mutating func mapFileBacked(
        baseAddress: UInt64,
        memorySize: UInt64,
        protection: MemoryProtection,
        label: String,
        data: Data,
        sourceOffset: Int,
        fileSize: Int
    ) throws {
        guard sourceOffset >= 0, fileSize >= 0, UInt64(fileSize) <= memorySize else {
            throw VirtualMemoryError.overflow
        }
        let (sourceEnd, sourceOverflow) = sourceOffset.addingReportingOverflow(fileSize)
        guard !sourceOverflow, sourceEnd <= data.count else {
            throw VirtualMemoryError.overflow
        }

        try map(
            baseAddress: baseAddress,
            size: memorySize,
            protection: protection,
            label: label
        )
        if fileSize > 0 {
            fileBackings.append(FileBacking(
                baseAddress: baseAddress,
                length: UInt64(fileSize),
                data: data,
                sourceOffset: sourceOffset
            ))
        }
    }

    mutating func write(_ data: Data, at address: UInt64, bypassProtection: Bool = false) throws {
        guard !data.isEmpty else { return }
        let region = try containingRegion(address: address, length: data.count)
        if !bypassProtection, !region.protection.contains(.write) {
            throw VirtualMemoryError.protection(address: address, required: .write)
        }

        var sourceOffset = 0
        var targetAddress = address
        while sourceOffset < data.count {
            let pageBase = targetAddress & ~(Self.pageSize - 1)
            let pageOffset = Int(targetAddress - pageBase)
            let count = min(data.count - sourceOffset, Int(Self.pageSize) - pageOffset)
            var page = pages[pageBase] ?? materializedPage(at: pageBase)
            for index in 0..<count {
                page[pageOffset + index] = data[sourceOffset + index]
            }
            pages[pageBase] = page
            sourceOffset += count
            targetAddress += UInt64(count)
        }
    }

    func read(at address: UInt64, length: Int) throws -> Data {
        try read(at: address, length: length, requiring: .read)
    }

    func fetch(at address: UInt64, length: Int) throws -> Data {
        try read(at: address, length: length, requiring: .execute)
    }

    func readIgnoringProtection(at address: UInt64, length: Int) throws -> Data {
        try read(at: address, length: length, requiring: nil)
    }

    private func read(at address: UInt64, length: Int, requiring protection: MemoryProtection?) throws -> Data {
        guard length > 0 else { return Data() }
        let region = try containingRegion(address: address, length: length)
        if let protection, !region.protection.contains(protection) {
            throw VirtualMemoryError.protection(address: address, required: protection)
        }

        var output = Data(capacity: length)
        var remaining = length
        var sourceAddress = address
        while remaining > 0 {
            let pageBase = sourceAddress & ~(Self.pageSize - 1)
            let pageOffset = Int(sourceAddress - pageBase)
            let count = min(remaining, Int(Self.pageSize) - pageOffset)
            if let page = pages[pageBase] {
                output.append(contentsOf: page[pageOffset..<(pageOffset + count)])
            } else {
                appendFileBackedBytes(to: &output, at: sourceAddress, length: count)
            }
            remaining -= count
            sourceAddress += UInt64(count)
        }
        return output
    }

    private func materializedPage(at pageBase: UInt64) -> [UInt8] {
        var page = [UInt8](repeating: 0, count: Int(Self.pageSize))
        let pageEnd = pageBase + Self.pageSize
        for backing in fileBackings where pageBase < backing.endAddress && pageEnd > backing.baseAddress {
            let copyStart = max(pageBase, backing.baseAddress)
            let copyEnd = min(pageEnd, backing.endAddress)
            let count = Int(copyEnd - copyStart)
            let destination = Int(copyStart - pageBase)
            let source = backing.sourceOffset + Int(copyStart - backing.baseAddress)
            for index in 0..<count {
                page[destination + index] = backing.data[source + index]
            }
        }
        return page
    }

    private func appendFileBackedBytes(to output: inout Data, at address: UInt64, length: Int) {
        guard let backing = fileBackings.first(where: { address >= $0.baseAddress && address < $0.endAddress }) else {
            output.append(contentsOf: repeatElement(UInt8(0), count: length))
            return
        }

        let available = min(length, Int(backing.endAddress - address))
        let source = backing.sourceOffset + Int(address - backing.baseAddress)
        output.append(backing.data[source..<(source + available)])
        if available < length {
            output.append(contentsOf: repeatElement(UInt8(0), count: length - available))
        }
    }

    private func containingRegion(address: UInt64, length: Int) throws -> VirtualMemoryRegion {
        guard length >= 0 else { throw VirtualMemoryError.overflow }
        let (end, overflow) = address.addingReportingOverflow(UInt64(length))
        guard !overflow else { throw VirtualMemoryError.overflow }
        guard let region = regions.first(where: { address >= $0.baseAddress && end <= $0.endAddress }) else {
            throw VirtualMemoryError.unmapped(address: address, length: length)
        }
        return region
    }
}
