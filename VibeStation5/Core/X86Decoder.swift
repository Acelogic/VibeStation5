// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CCapstone
import Foundation

enum X86OperandValue: Sendable {
    case register(String)
    case immediate(UInt64)
    case memory(X86MemoryOperand)
}

struct X86MemoryOperand: Sendable {
    let segment: String?
    let base: String?
    let index: String?
    let scale: Int
    let displacement: Int64
}

struct X86Operand: Sendable {
    let size: Int
    let access: UInt8
    let value: X86OperandValue
}

struct X86Instruction: Sendable {
    let address: UInt64
    let size: Int
    let mnemonic: String
    let operandText: String
    let operands: [X86Operand]

    var nextAddress: UInt64 { address + UInt64(size) }
    var text: String {
        operandText.isEmpty ? mnemonic : "\(mnemonic) \(operandText)"
    }
}

enum X86DecoderError: Error, LocalizedError {
    case initialization
    case undecodable(address: UInt64, detail: String)

    var errorDescription: String? {
        switch self {
        case .initialization:
            "The ARM-native x86-64 decoder could not be initialized."
        case let .undecodable(address, detail):
            "x86-64 decode failed at \(address.hexadecimal): \(detail)"
        }
    }
}

final class X86Decoder: @unchecked Sendable {
    private let decoder: OpaquePointer

    init() throws {
        guard let decoder = vs_decoder_create() else {
            throw X86DecoderError.initialization
        }
        self.decoder = decoder
    }

    deinit {
        vs_decoder_destroy(decoder)
    }

    func decode(memory: SparseVirtualMemory, at address: UInt64) throws -> X86Instruction {
        let bytes = try memory.fetch(at: address, length: 15)
        var rawInstruction = vs_instruction()
        let decoded = bytes.withUnsafeBytes { rawBytes -> Bool in
            guard let baseAddress = rawBytes.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return vs_decode_one(
                decoder,
                baseAddress,
                bytes.count,
                address,
                &rawInstruction
            )
        }
        guard decoded else {
            let detail = String(cString: vs_decoder_error(decoder))
            throw X86DecoderError.undecodable(address: address, detail: detail)
        }

        var operands: [X86Operand] = []
        withUnsafePointer(to: &rawInstruction.operands) { tuplePointer in
            tuplePointer.withMemoryRebound(to: vs_operand.self, capacity: 8) { operandPointer in
                for index in 0..<Int(rawInstruction.operand_count) {
                    let operand = operandPointer[index]
                    let value: X86OperandValue
                    switch operand.kind {
                    case UInt8(VS_OPERAND_REGISTER.rawValue):
                        value = .register(registerName(operand.register_id))
                    case UInt8(VS_OPERAND_IMMEDIATE.rawValue):
                        value = .immediate(operand.immediate)
                    case UInt8(VS_OPERAND_MEMORY.rawValue):
                        let memory = operand.memory
                        value = .memory(X86MemoryOperand(
                            segment: optionalRegisterName(memory.segment),
                            base: optionalRegisterName(memory.base),
                            index: optionalRegisterName(memory.index),
                            scale: Int(memory.scale),
                            displacement: memory.displacement
                        ))
                    default:
                        continue
                    }
                    operands.append(X86Operand(
                        size: Int(operand.size),
                        access: operand.access,
                        value: value
                    ))
                }
            }
        }

        return X86Instruction(
            address: rawInstruction.address,
            size: Int(rawInstruction.size),
            mnemonic: String(cString: vs_decoder_mnemonic(decoder)),
            operandText: String(cString: vs_decoder_operand_text(decoder)),
            operands: operands
        )
    }

    private func optionalRegisterName(_ identifier: UInt32) -> String? {
        let name = registerName(identifier)
        return name.isEmpty ? nil : name
    }

    private func registerName(_ identifier: UInt32) -> String {
        String(cString: vs_decoder_register_name(decoder, identifier))
    }
}
