// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum BinaryFormatError: Error, Equatable, LocalizedError {
    case truncated(context: String, offset: Int, length: Int)
    case invalid(String)
    case unsupported(String)
    case arithmeticOverflow(String)

    var errorDescription: String? {
        switch self {
        case let .truncated(context, offset, length):
            "\(context) is truncated at offset \(offset) (needed \(length) bytes)."
        case let .invalid(message):
            message
        case let .unsupported(message):
            message
        case let .arithmeticOverflow(message):
            message
        }
    }
}

extension Data {
    func checkedRange(offset: Int, count: Int, context: String) throws -> Range<Int> {
        guard offset >= 0, count >= 0 else {
            throw BinaryFormatError.invalid("\(context) uses a negative range.")
        }
        let (end, overflow) = offset.addingReportingOverflow(count)
        guard !overflow else {
            throw BinaryFormatError.arithmeticOverflow("\(context) range overflowed.")
        }
        guard end <= self.count else {
            throw BinaryFormatError.truncated(context: context, offset: offset, length: count)
        }
        return offset..<end
    }

    func byte(at offset: Int, context: String = "Binary") throws -> UInt8 {
        let range = try checkedRange(offset: offset, count: 1, context: context)
        return self[range.lowerBound]
    }

    func uint16LE(at offset: Int, context: String = "Binary") throws -> UInt16 {
        let range = try checkedRange(offset: offset, count: 2, context: context)
        return UInt16(self[range.lowerBound]) |
            (UInt16(self[range.lowerBound + 1]) << 8)
    }

    func uint32LE(at offset: Int, context: String = "Binary") throws -> UInt32 {
        let range = try checkedRange(offset: offset, count: 4, context: context)
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[range.lowerBound + index]) << UInt32(index * 8)
        }
        return value
    }

    func uint32BE(at offset: Int, context: String = "Binary") throws -> UInt32 {
        let range = try checkedRange(offset: offset, count: 4, context: context)
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(self[range.lowerBound + index])
        }
        return value
    }

    func uint64LE(at offset: Int, context: String = "Binary") throws -> UInt64 {
        let range = try checkedRange(offset: offset, count: 8, context: context)
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[range.lowerBound + index]) << UInt64(index * 8)
        }
        return value
    }

    func bytes(at offset: Int, count: Int, context: String = "Binary") throws -> Data {
        let range = try checkedRange(offset: offset, count: count, context: context)
        return subdata(in: range)
    }
}

extension UInt64 {
    var hexadecimal: String {
        String(format: "0x%016llX", self)
    }
}

