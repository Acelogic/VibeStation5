// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum ARMExecutionStopReason: Equatable, Sendable {
    case sentinelReturn
    case instructionBudget
    case systemCall(UInt64)
    case halted(String)
    case unsupportedInstruction(String)
    case fault(String)

    var text: String {
        switch self {
        case .sentinelReturn:
            "Guest entry point returned to the host sentinel."
        case .instructionBudget:
            "The ARM interpreter reached its instruction budget."
        case let .systemCall(number):
            "Guest issued system call \(number)."
        case let .halted(reason):
            "Guest halted: \(reason)"
        case let .unsupportedInstruction(instruction):
            "Unsupported x86-64 instruction: \(instruction)"
        case let .fault(message):
            "Guest CPU fault: \(message)"
        }
    }
}

struct ARMExecutionReport: Sendable {
    let instructionCount: Int
    let interceptedImportCount: Int
    let finalInstructionPointer: UInt64
    let reason: ARMExecutionStopReason
    let recentInstructions: [String]
    let recentImports: [String]
    let importCounts: [String: Int]
    let guestThreadCount: Int
    let contextSwitchCount: Int
    let guestThreads: [ARMGuestThreadSnapshot]
    let guestHotspots: [ARMGuestHotspot]
    let finalRegisters: [String: UInt64]
    let runtimeEvents: [String]
    let videoFrame: GuestVideoFrame?
}

struct GuestVideoFrame: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelFormat: UInt64
    let bufferIndex: Int
    let flipCount: UInt64
    let sourceAddress: UInt64
    let bgra8Data: Data
    let nonzeroByteCount: Int

    var hasVisibleContent: Bool { nonzeroByteCount > 0 }
}

struct ARMGuestThreadSnapshot: Sendable {
    let handle: UInt64
    let entryPoint: UInt64
    let instructionCount: Int
    let instructionPointer: UInt64
    let status: String
}

struct ARMGuestHotspot: Sendable {
    let threadHandle: UInt64
    let instructionPointer: UInt64
    let samples: Int
}

enum ARMInterpreterError: Error, LocalizedError {
    case invalidOperand(String)
    case unknownRegister(String)
    case unsupportedWidth(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidOperand(detail): "Invalid x86-64 operand: \(detail)"
        case let .unknownRegister(name): "Unknown x86-64 register \(name)."
        case let .unsupportedWidth(width): "Unsupported x86-64 operand width \(width) bytes."
        }
    }
}

struct ARMNativeX86Interpreter: Sendable {
    static let stackBase: UInt64 = 0x0000_7FFF_0000_0000
    static let stackSize: UInt64 = 256 * 1_024 * 1_024
    static let heapBase: UInt64 = 0x0000_000A_0000_0000
    static let heapSize: UInt64 = 2 * 1_024 * 1_024 * 1_024
    static let threadLocalStorageBase: UInt64 = 0x0000_000C_0000_0000
    static let threadLocalStorageBlockSize: UInt64 = 64 * 1_024
    static let threadLocalStorageSize: UInt64 = 16 * 1_024 * 1_024
    static let threadControlBlockOffset: UInt64 = 32 * 1_024
    static let guestThreadStackSize: UInt64 = 2 * 1_024 * 1_024
    static let guestThreadQuantum = 10_000
    static let returnSentinel: UInt64 = 0xFFFF_FFFF_FFFF_FFF0

    private let decoder: X86Decoder
    private let gameRootURL: URL?
    private let jsonTokenEntryFastPathEnabled: Bool
    private let jsonNumberFastPathEnabled: Bool
    private let jsonTokenReturnFastPathEnabled: Bool
    private let stopAfterFirstJSONDouble: Bool
    private let stopAfterFirstAGCFlip: Bool
    private let stopAfterFirstAGCSubmit: Bool
    private let stopAfterMenuFlip: Bool
    private let stopAfterMenuSubmit: Bool
    private let stopAfterMenuSubmitCount: UInt64?
    private let stopAfterFirstMenuDrawBatch: Bool
    private let variantMoveFastPathEnabled: Bool
    private let variantDestructionFastPathsEnabled: Bool
    private let videoFrameHandler: (@Sendable (GuestVideoFrame) -> Void)?
    private let audioBufferHandler: (@Sendable (GuestAudioBuffer) -> Void)?
    private let inputStateProvider: (@Sendable () -> GuestInputState)?
    private let runtimeEventHandler: (@Sendable (String) -> Void)?
    private let audioPorts = GuestAudioPortTable()

    init(
        gameRootURL: URL? = nil,
        videoFrameHandler: (@Sendable (GuestVideoFrame) -> Void)? = nil,
        audioBufferHandler: (@Sendable (GuestAudioBuffer) -> Void)? = nil,
        inputStateProvider: (@Sendable () -> GuestInputState)? = nil,
        runtimeEventHandler: (@Sendable (String) -> Void)? = nil
    ) throws {
        self.gameRootURL = gameRootURL?.standardizedFileURL
        self.videoFrameHandler = videoFrameHandler
        self.audioBufferHandler = audioBufferHandler
        self.inputStateProvider = inputStateProvider
        self.runtimeEventHandler = runtimeEventHandler
        let environment = ProcessInfo.processInfo.environment
        jsonTokenEntryFastPathEnabled = environment["VS5_DISABLE_JSON_TOKEN_ENTRY"] != "1"
        jsonNumberFastPathEnabled = environment["VS5_DISABLE_JSON_NUMBER"] != "1"
        jsonTokenReturnFastPathEnabled = environment["VS5_DISABLE_JSON_TOKEN_RETURN"] != "1"
        stopAfterFirstJSONDouble = environment["VS5_STOP_AFTER_FIRST_JSON_DOUBLE"] == "1"
        stopAfterFirstAGCFlip = environment["VS5_STOP_AFTER_FIRST_AGC_FLIP"] == "1"
        stopAfterFirstAGCSubmit = environment["VS5_STOP_AFTER_FIRST_AGC_SUBMIT"] == "1"
        stopAfterMenuFlip = environment["VS5_STOP_AFTER_MENU_FLIP"] == "1"
        stopAfterMenuSubmit = environment["VS5_STOP_AFTER_MENU_SUBMIT"] == "1"
        stopAfterMenuSubmitCount = environment["VS5_STOP_AFTER_MENU_SUBMIT_COUNT"].flatMap(UInt64.init)
        stopAfterFirstMenuDrawBatch = environment["VS5_STOP_AFTER_FIRST_MENU_DRAW_BATCH"] == "1"
        variantMoveFastPathEnabled = environment["VS5_DISABLE_VARIANT_MOVE"] != "1"
        variantDestructionFastPathsEnabled = environment["VS5_DISABLE_VARIANT_DESTRUCTION"] != "1"
        decoder = try X86Decoder()
    }

    func run(
        memory: inout SparseVirtualMemory,
        entryPoint: UInt64,
        importSymbolsByIndex: [Int: String] = [:],
        instructionBudget: Int = 100_000
    ) throws -> ARMExecutionReport {
        try memory.map(
            baseAddress: Self.stackBase,
            size: Self.stackSize,
            protection: [.read, .write],
            label: "ARM interpreter guest stack"
        )
        try memory.map(
            baseAddress: Self.heapBase,
            size: Self.heapSize,
            protection: [.read, .write],
            label: "ARM interpreter guest heap"
        )
        try memory.map(
            baseAddress: Self.threadLocalStorageBase,
            size: Self.threadLocalStorageSize,
            protection: [.read, .write],
            label: "ARM interpreter initial thread-local storage"
        )

        var state = X86CPUState(rip: entryPoint)
        state.fsBase = Self.threadLocalStorageBase + Self.threadControlBlockOffset
        state.gsBase = state.fsBase
        try writeInteger(state.fsBase, size: 8, to: state.fsBase, memory: &memory)
        let processArguments = Self.stackBase + 0x1000
        state.writeRegister("rdi", value: processArguments)
        state.writeRegister("rsi", value: 0)
        state.writeRegister("rsp", value: Self.stackBase + Self.stackSize - 0x100)
        try writeInteger(1, size: 8, to: processArguments, memory: &memory)
        try writeInteger(processArguments + 0x100, size: 8, to: processArguments + 8, memory: &memory)
        try writeInteger(0, size: 8, to: processArguments + 16, memory: &memory)
        try memory.write(Data("eboot.bin\0".utf8), at: processArguments + 0x100)
        try push(Self.returnSentinel, state: &state, memory: &memory)

        var recentInstructions: [String] = []
        var recentImports: [String] = []
        var importCounts: [String: Int] = [:]
        var runtimeEvents: [String] = []
        var interceptedImports = 0
        var heapCursor = Self.heapBase
        var allocations: [UInt64: UInt64] = [:]
        var openFiles: [UInt64: GuestOpenFile] = [:]
        var runtimeObjects: [String: UInt64] = [:]
        var readyContexts: [RunnableGuestContext] = []
        var sleepingContexts: [SleepingGuestContext] = []
        var mutexStates: [UInt64: GuestMutexState] = [:]
        var mutexWaiters: [UInt64: [GuestMutexWaiter]] = [:]
        var activeThreadHandle: UInt64 = 1
        var threadReturnValues: [UInt64: UInt64] = [:]
        var joinWaiters: [UInt64: [GuestJoinWaiter]] = [:]
        var guestThreadCount = 1
        var contextSwitchCount = 0
        var threadEntryPoints: [UInt64: UInt64] = [1: entryPoint]
        var threadInstructionCounts: [UInt64: Int] = [:]
        var threadLastInstructionPointers: [UInt64: UInt64] = [1: entryPoint]
        var threadHotSamples: [UInt64: [UInt64: Int]] = [:]
        var threadSliceStart = 0
        var contentPriorityStreak = 0
        var nextThreadStackTop = Self.stackBase + Self.stackSize - Self.guestThreadStackSize - 0x100
        var nextThreadTLSBlock = Self.threadLocalStorageBase + Self.threadLocalStorageBlockSize
        for count in 0..<instructionBudget {
            if !sleepingContexts.isEmpty, count.isMultiple(of: 1_000) {
                var stillSleeping: [SleepingGuestContext] = []
                for sleeper in sleepingContexts {
                    if sleeper.wakeInstruction <= count {
                        if let mutex = sleeper.mutexToReacquire {
                            if var mutexState = mutexStates[mutex] {
                                if mutexState.owner == sleeper.context.threadHandle {
                                    mutexState.depth += max(sleeper.mutexDepth, 1)
                                    mutexStates[mutex] = mutexState
                                    readyContexts.append(sleeper.context)
                                } else {
                                    mutexWaiters[mutex, default: []].append(
                                        GuestMutexWaiter(
                                            context: sleeper.context,
                                            depth: max(sleeper.mutexDepth, 1)
                                        )
                                    )
                                }
                            } else {
                                mutexStates[mutex] = GuestMutexState(
                                    owner: sleeper.context.threadHandle,
                                    depth: max(sleeper.mutexDepth, 1)
                                )
                                readyContexts.append(sleeper.context)
                            }
                        } else {
                            readyContexts.append(sleeper.context)
                        }
                    } else {
                        stillSleeping.append(sleeper)
                    }
                }
                sleepingContexts = stillSleeping
            }
            if count > 0,
               count.isMultiple(of: Self.guestThreadQuantum),
               !readyContexts.isEmpty {
                threadInstructionCounts[activeThreadHandle, default: 0] += count - threadSliceStart
                threadLastInstructionPointers[activeThreadHandle] = state.rip
                readyContexts.append(RunnableGuestContext(
                    state: state,
                    threadHandle: activeThreadHandle
                ))
                let next = dequeueNextReadyContext(
                    from: &readyContexts,
                    preferredHandle: runtimeObjects["scheduler.startupContentThread"],
                    priorityStreak: &contentPriorityStreak
                )
                state = next.state
                activeThreadHandle = next.threadHandle
                threadSliceStart = count
                contextSwitchCount += 1
            }
            if count.isMultiple(of: 1_000) {
                if runtimeObjects["json.parser.reachedEOF"] == 1,
                   let contentThread = runtimeObjects["scheduler.startupContentThread"] {
                    threadHotSamples[contentThread] = [:]
                    runtimeObjects["json.parser.reachedEOF"] = 2
                }
                threadHotSamples[activeThreadHandle, default: [:]][state.rip, default: 0] += 1
            }

            let instruction: X86Instruction
            do {
                instruction = try decoder.decode(memory: memory, at: state.rip)
            } catch {
                return report(
                    count: count,
                    interceptedImports: interceptedImports,
                    state: state,
                    reason: .fault(error.localizedDescription),
                    recent: recentInstructions,
                    imports: recentImports,
                    importCounts: importCounts,
                    guestThreadCount: guestThreadCount,
                    contextSwitchCount: contextSwitchCount,
                    activeThreadHandle: activeThreadHandle,
                    readyContexts: readyContexts,
                    sleepingContexts: sleepingContexts,
                    joinWaiters: joinWaiters,
                    threadReturnValues: threadReturnValues,
                    threadEntryPoints: threadEntryPoints,
                    threadInstructionCounts: threadInstructionCounts,
                    threadLastInstructionPointers: threadLastInstructionPointers,
                    threadHotSamples: threadHotSamples,
                    threadSliceStart: threadSliceStart,
                    runtimeEvents: runtimeEvents,
                    memory: memory,
                    runtimeObjects: runtimeObjects
                )
            }

            recentInstructions.append(
                "\(instruction.address.hexadecimal): \(instruction.text)"
            )
            if recentInstructions.count > 24 {
                recentInstructions.removeFirst()
            }

            do {
                let executingThreadHandle = activeThreadHandle
                let reason = try execute(
                    instruction,
                    state: &state,
                    memory: &memory,
                    interceptedImports: &interceptedImports,
                    importSymbolsByIndex: importSymbolsByIndex,
                    recentImports: &recentImports,
                    importCounts: &importCounts,
                    runtimeEvents: &runtimeEvents,
                    heapCursor: &heapCursor,
                    allocations: &allocations,
                    openFiles: &openFiles,
                    runtimeObjects: &runtimeObjects,
                    readyContexts: &readyContexts,
                    sleepingContexts: &sleepingContexts,
                    mutexStates: &mutexStates,
                    mutexWaiters: &mutexWaiters,
                    currentInstruction: count,
                    activeThreadHandle: &activeThreadHandle,
                    threadReturnValues: &threadReturnValues,
                    joinWaiters: &joinWaiters,
                    guestThreadCount: &guestThreadCount,
                    contextSwitchCount: &contextSwitchCount,
                    nextThreadStackTop: &nextThreadStackTop,
                    nextThreadTLSBlock: &nextThreadTLSBlock
                )
                if activeThreadHandle != executingThreadHandle {
                    threadInstructionCounts[executingThreadHandle, default: 0] +=
                        count + 1 - threadSliceStart
                    threadLastInstructionPointers[executingThreadHandle] = instruction.address
                    threadSliceStart = count + 1
                    if threadEntryPoints[activeThreadHandle] == nil {
                        threadEntryPoints[activeThreadHandle] = state.rip
                    }
                }
                if let reason {
                    return report(
                        count: count + 1,
                        interceptedImports: interceptedImports,
                        state: state,
                        reason: reason,
                        recent: recentInstructions,
                        imports: recentImports,
                        importCounts: importCounts,
                        guestThreadCount: guestThreadCount,
                        contextSwitchCount: contextSwitchCount,
                        activeThreadHandle: activeThreadHandle,
                        readyContexts: readyContexts,
                        sleepingContexts: sleepingContexts,
                        joinWaiters: joinWaiters,
                        threadReturnValues: threadReturnValues,
                        threadEntryPoints: threadEntryPoints,
                        threadInstructionCounts: threadInstructionCounts,
                        threadLastInstructionPointers: threadLastInstructionPointers,
                        threadHotSamples: threadHotSamples,
                        threadSliceStart: threadSliceStart,
                        runtimeEvents: runtimeEvents,
                        memory: memory,
                        runtimeObjects: runtimeObjects
                    )
                }
            } catch {
                return report(
                    count: count + 1,
                    interceptedImports: interceptedImports,
                    state: state,
                    reason: .fault(error.localizedDescription),
                    recent: recentInstructions,
                    imports: recentImports,
                    importCounts: importCounts,
                    guestThreadCount: guestThreadCount,
                    contextSwitchCount: contextSwitchCount,
                    activeThreadHandle: activeThreadHandle,
                    readyContexts: readyContexts,
                    sleepingContexts: sleepingContexts,
                    joinWaiters: joinWaiters,
                    threadReturnValues: threadReturnValues,
                    threadEntryPoints: threadEntryPoints,
                    threadInstructionCounts: threadInstructionCounts,
                    threadLastInstructionPointers: threadLastInstructionPointers,
                    threadHotSamples: threadHotSamples,
                    threadSliceStart: threadSliceStart,
                    runtimeEvents: runtimeEvents,
                    memory: memory,
                    runtimeObjects: runtimeObjects
                )
            }
        }

        return report(
            count: instructionBudget,
            interceptedImports: interceptedImports,
            state: state,
            reason: .instructionBudget,
            recent: recentInstructions,
            imports: recentImports,
            importCounts: importCounts,
            guestThreadCount: guestThreadCount,
            contextSwitchCount: contextSwitchCount,
            activeThreadHandle: activeThreadHandle,
            readyContexts: readyContexts,
            sleepingContexts: sleepingContexts,
            joinWaiters: joinWaiters,
            threadReturnValues: threadReturnValues,
            threadEntryPoints: threadEntryPoints,
            threadInstructionCounts: threadInstructionCounts,
            threadLastInstructionPointers: threadLastInstructionPointers,
            threadHotSamples: threadHotSamples,
            threadSliceStart: threadSliceStart,
            runtimeEvents: runtimeEvents,
            memory: memory,
            runtimeObjects: runtimeObjects
        )
    }

    private func report(
        count: Int,
        interceptedImports: Int,
        state: X86CPUState,
        reason: ARMExecutionStopReason,
        recent: [String],
        imports: [String],
        importCounts: [String: Int],
        guestThreadCount: Int,
        contextSwitchCount: Int,
        activeThreadHandle: UInt64,
        readyContexts: [RunnableGuestContext],
        sleepingContexts: [SleepingGuestContext],
        joinWaiters: [UInt64: [GuestJoinWaiter]],
        threadReturnValues: [UInt64: UInt64],
        threadEntryPoints: [UInt64: UInt64],
        threadInstructionCounts: [UInt64: Int],
        threadLastInstructionPointers: [UInt64: UInt64],
        threadHotSamples: [UInt64: [UInt64: Int]],
        threadSliceStart: Int,
        runtimeEvents: [String],
        memory: SparseVirtualMemory,
        runtimeObjects: [String: UInt64]
    ) -> ARMExecutionReport {
        var instructionCounts = threadInstructionCounts
        instructionCounts[activeThreadHandle, default: 0] += max(0, count - threadSliceStart)
        var positions = threadLastInstructionPointers
        var statuses: [UInt64: String] = [:]
        positions[activeThreadHandle] = state.rip
        statuses[activeThreadHandle] = "running"
        for context in readyContexts where statuses[context.threadHandle] == nil {
            positions[context.threadHandle] = context.state.rip
            statuses[context.threadHandle] = "ready"
        }
        for sleeper in sleepingContexts where statuses[sleeper.context.threadHandle] == nil {
            positions[sleeper.context.threadHandle] = sleeper.context.state.rip
            statuses[sleeper.context.threadHandle] = "sleeping"
        }
        for waiters in joinWaiters.values {
            for waiter in waiters where statuses[waiter.context.threadHandle] == nil {
                positions[waiter.context.threadHandle] = waiter.context.state.rip
                statuses[waiter.context.threadHandle] = "join-wait"
            }
        }
        for handle in threadReturnValues.keys where statuses[handle] == nil {
            statuses[handle] = "exited"
        }
        let threadHandles = Set(threadEntryPoints.keys)
            .union(instructionCounts.keys)
            .union(statuses.keys)
        let guestThreads = threadHandles.sorted().map { handle in
            ARMGuestThreadSnapshot(
                handle: handle,
                entryPoint: threadEntryPoints[handle] ?? 0,
                instructionCount: instructionCounts[handle] ?? 0,
                instructionPointer: positions[handle] ?? 0,
                status: statuses[handle] ?? "unknown"
            )
        }
        let guestHotspots = threadHotSamples.flatMap { handle, samplesByAddress in
            samplesByAddress
                .sorted {
                    if $0.value == $1.value { return $0.key < $1.key }
                    return $0.value > $1.value
                }
                .prefix(8)
                .map { address, samples in
                    ARMGuestHotspot(
                        threadHandle: handle,
                        instructionPointer: address,
                        samples: samples
                    )
                }
        }.sorted {
            if $0.threadHandle == $1.threadHandle {
                if $0.samples == $1.samples {
                    return $0.instructionPointer < $1.instructionPointer
                }
                return $0.samples > $1.samples
            }
            return $0.threadHandle < $1.threadHandle
        }
        return ARMExecutionReport(
            instructionCount: count,
            interceptedImportCount: interceptedImports,
            finalInstructionPointer: state.rip,
            reason: reason,
            recentInstructions: recent,
            recentImports: imports,
            importCounts: importCounts,
            guestThreadCount: guestThreadCount,
            contextSwitchCount: contextSwitchCount,
            guestThreads: guestThreads,
            guestHotspots: guestHotspots,
            finalRegisters: Dictionary(uniqueKeysWithValues: [
                "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
                "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"
            ].map { ($0, state.readRegister($0)) }),
            runtimeEvents: runtimeEvents,
            videoFrame: captureVideoFrame(memory: memory, runtimeObjects: runtimeObjects)
        )
    }

    private func captureVideoFrame(
        memory: SparseVirtualMemory,
        runtimeObjects: [String: UInt64]
    ) -> GuestVideoFrame? {
        let widthValue = runtimeObjects["videoout.width", default: 0]
        let heightValue = runtimeObjects["videoout.height", default: 0]
        guard widthValue > 0, heightValue > 0,
              widthValue <= 8_192, heightValue <= 8_192 else {
            return nil
        }

        let requestedIndex = runtimeObjects["videoout.currentBuffer", default: 0]
        var selectedIndex = requestedIndex
        var address = runtimeObjects["videoout.buffer.\(requestedIndex)", default: 0]
        if address == 0 {
            for index in 0..<16 {
                let candidate = runtimeObjects["videoout.buffer.\(index)", default: 0]
                if candidate != 0 {
                    selectedIndex = UInt64(index)
                    address = candidate
                    break
                }
            }
        }
        guard address != 0 else { return nil }

        let (pixelCount, pixelOverflow) = widthValue.multipliedReportingOverflow(by: heightValue)
        let (byteCountValue, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow,
              byteCountValue <= UInt64(Int.max) else {
            return nil
        }
        let byteCount = Int(byteCountValue)
        guard let data = try? memory.readIgnoringProtection(at: address, length: byteCount) else {
            return nil
        }
        let nonzeroByteCount = data.reduce(into: 0) { count, byte in
            if byte != 0 { count += 1 }
        }
        return GuestVideoFrame(
            width: Int(widthValue),
            height: Int(heightValue),
            bytesPerRow: Int(widthValue) * 4,
            pixelFormat: runtimeObjects["videoout.pixelFormat", default: 0],
            bufferIndex: Int(selectedIndex),
            flipCount: runtimeObjects["videoout.flipCount", default: 0],
            sourceAddress: address,
            bgra8Data: data,
            nonzeroByteCount: nonzeroByteCount
        )
    }

    private func publishVideoFrameIfNeeded(
        memory: SparseVirtualMemory,
        runtimeObjects: [String: UInt64]
    ) {
        guard let videoFrameHandler else { return }
        let flipCount = runtimeObjects["videoout.flipCount", default: 0]
        guard flipCount == 1 || flipCount.isMultiple(of: 30) else { return }
        if let frame = captureVideoFrame(memory: memory, runtimeObjects: runtimeObjects) {
            videoFrameHandler(frame)
        }
    }

    private func summarizeAGCCommandBuffer(
        address: UInt64,
        dwordCount: UInt64,
        memory: SparseVirtualMemory
    ) throws -> AGCCommandBufferSummary {
        let inspectedDwordCount = Int(min(dwordCount, 65_536))
        var offset = 0
        var packetCount = 0
        var flipPacketCount = 0
        var signatures: [String: Int] = [:]
        var shRegisters: [UInt64: UInt64] = [:]
        var cxRegisters: [UInt64: UInt64] = [:]
        var ucRegisters: [UInt64: UInt64] = [:]
        var indexAddress: UInt64?
        var indexBufferSize: UInt64?
        var indexType: UInt64?
        var drawIndexOffset: UInt64?
        var drawIndexCount: UInt64?
        var instanceCount: UInt64?
        while offset < inspectedDwordCount {
            let packetAddress = address + UInt64(offset * 4)
            let header = try readInteger(
                size: 4,
                from: packetAddress,
                memory: memory
            )
            let packetType = Int((header >> 30) & 0x3)
            let packetLength: Int
            let signature: String
            if header == 0x8000_0000 {
                packetLength = 1
                signature = "marker"
            } else if packetType == 3 {
                packetLength = Int((header >> 16) & 0x3FFF) + 2
                let opcode = (header >> 8) & 0xFF
                let register = (header >> 2) & 0x3F
                signature = String(
                    format: "t3/op%02llX/r%02llX",
                    opcode,
                    register
                )
                if opcode == 0x10, register == 0x17 {
                    flipPacketCount += 1
                } else if opcode == 0x10, register == 0x04, packetLength >= 2 {
                    drawIndexCount = try readInteger(
                        size: 4,
                        from: packetAddress + 4,
                        memory: memory
                    )
                } else if opcode == 0x10,
                          [UInt64(0x11), 0x12, 0x13].contains(register),
                          packetLength >= 4 {
                    let registerCount = try readInteger(
                        size: 4,
                        from: packetAddress + 4,
                        memory: memory
                    )
                    let registersAddress = try readInteger(
                        size: 8,
                        from: packetAddress + 8,
                        memory: memory
                    )
                    let inspectedRegisterCount = min(registerCount, 16_384)
                    for registerIndex in 0..<inspectedRegisterCount {
                        let entryAddress = registersAddress + registerIndex * 8
                        let registerOffset = try readInteger(
                            size: 4,
                            from: entryAddress,
                            memory: memory
                        )
                        let value = try readInteger(
                            size: 4,
                            from: entryAddress + 4,
                            memory: memory
                        )
                        switch register {
                        case 0x11: shRegisters[registerOffset] = value
                        case 0x12: cxRegisters[registerOffset] = value
                        default: ucRegisters[registerOffset] = value
                        }
                    }
                } else if [UInt64(0x69), 0x76, 0x79].contains(opcode),
                          packetLength >= 3 {
                    let startRegister = try readInteger(
                        size: 4,
                        from: packetAddress + 4,
                        memory: memory
                    )
                    let valueCount = UInt64(packetLength - 2)
                    for valueIndex in 0..<valueCount {
                        let value = try readInteger(
                            size: 4,
                            from: packetAddress + 8 + valueIndex * 4,
                            memory: memory
                        )
                        switch opcode {
                        case 0x69: cxRegisters[startRegister + valueIndex] = value
                        case 0x76: shRegisters[startRegister + valueIndex] = value
                        default: ucRegisters[startRegister + valueIndex] = value
                        }
                    }
                } else if opcode == 0x26, packetLength >= 3 {
                    indexAddress = try readInteger(
                        size: 8,
                        from: packetAddress + 4,
                        memory: memory
                    )
                } else if opcode == 0x13, packetLength >= 2 {
                    indexBufferSize = try readInteger(
                        size: 4,
                        from: packetAddress + 4,
                        memory: memory
                    )
                } else if opcode == 0x2A, packetLength >= 2 {
                    indexType = try readInteger(
                        size: 4,
                        from: packetAddress + 4,
                        memory: memory
                    )
                } else if opcode == 0x2F, packetLength >= 2 {
                    instanceCount = try readInteger(
                        size: 4,
                        from: packetAddress + 4,
                        memory: memory
                    )
                } else if opcode == 0x35, packetLength >= 5 {
                    drawIndexOffset = try readInteger(
                        size: 4,
                        from: packetAddress + 8,
                        memory: memory
                    )
                    drawIndexCount = try readInteger(
                        size: 4,
                        from: packetAddress + 12,
                        memory: memory
                    )
                }
            } else if packetType == 0 {
                packetLength = Int((header >> 16) & 0x3FFF) + 2
                signature = "t0"
            } else {
                packetLength = 1
                signature = "t\(packetType)"
            }
            packetCount += 1
            signatures[signature, default: 0] += 1
            offset += max(1, min(packetLength, inspectedDwordCount - offset))
        }
        let signatureText = signatures
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .prefix(12)
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: ", ")
        func shaderAddress(lowRegister: UInt64, highRegister: UInt64) -> UInt64? {
            guard let low = shRegisters[lowRegister],
                  let high = shRegisters[highRegister] else {
                return nil
            }
            return ((low & 0xFFFF_FFFF) << 8) |
                ((high & 0x00FF_FFFF) << 40)
        }
        func cxAddress(baseRegister: UInt64, extensionRegister: UInt64) -> UInt64? {
            guard let base = cxRegisters[baseRegister] else { return nil }
            let addressExtension = cxRegisters[extensionRegister, default: 0]
            return ((base & 0xFFFF_FFFF) << 8) |
                ((addressExtension & 0x00FF_FFFF) << 40)
        }
        func hex(_ value: UInt64) -> String {
            String(format: "0x%016llX", value)
        }
        func registerRange(
            _ registers: [UInt64: UInt64],
            start: UInt64,
            count: UInt64
        ) -> String {
            (0..<count).map { index in
                String(
                    format: "%03llX=%08llX",
                    start + index,
                    registers[start + index, default: 0]
                )
            }.joined(separator: "/")
        }
        var state: [String] = []
        if let exportShaderAddress = shaderAddress(lowRegister: 0xC8, highRegister: 0xC9) {
            state.append("es=\(hex(exportShaderAddress))")
        }
        if let pixelShaderAddress = shaderAddress(lowRegister: 0x08, highRegister: 0x09) {
            state.append("ps=\(hex(pixelShaderAddress))")
        }
        if let renderTargetAddress = cxAddress(baseRegister: 0x318, extensionRegister: 0x390) {
            state.append("rt0=\(hex(renderTargetAddress))")
        }
        if let indexAddress { state.append("index=\(hex(indexAddress))") }
        if let indexBufferSize { state.append("indexBytes=\(indexBufferSize)") }
        if let indexType { state.append("indexType=\(indexType)") }
        if let drawIndexOffset { state.append("firstIndex=\(drawIndexOffset)") }
        if let drawIndexCount { state.append("indexCount=\(drawIndexCount)") }
        if let instanceCount { state.append("instances=\(instanceCount)") }
        if let primitiveType = ucRegisters[0x242] {
            state.append(String(format: "primitive=0x%llX", primitiveType))
        }
        if let targetMask = cxRegisters[0x08E] {
            state.append(String(format: "targetMask=0x%llX", targetMask))
        }
        if let pixelInputEnable = cxRegisters[0x1B3] {
            state.append(String(format: "psInput=0x%llX", pixelInputEnable))
        }
        if shRegisters.keys.contains(where: { (0x0C...0x1B).contains($0) }) {
            state.append("psUser=[\(registerRange(shRegisters, start: 0x0C, count: 16))]")
        }
        if shRegisters.keys.contains(where: { (0xCC...0xDB).contains($0) }) {
            state.append("esUser=[\(registerRange(shRegisters, start: 0xCC, count: 16))]")
        }
        if !shRegisters.isEmpty {
            let allShaderRegisters = shRegisters
                .sorted { $0.key < $1.key }
                .map { String(format: "%03llX=%08llX", $0.key, $0.value) }
                .joined(separator: "/")
            state.append("sh=[\(allShaderRegisters)]")
        }
        return AGCCommandBufferSummary(
            packetCount: packetCount,
            flipPacketCount: flipPacketCount,
            signatureText: signatureText.isEmpty ? "no packets" : signatureText,
            stateText: state.joined(separator: ", ")
        )
    }

    private func allocateAGCCommandDwords(
        count: UInt64,
        commandBuffer: UInt64,
        memory: inout SparseVirtualMemory
    ) throws -> UInt64? {
        guard count > 0, commandBuffer != 0 else { return nil }
        let cursorUp = try readInteger(
            size: 8,
            from: commandBuffer + 0x10,
            memory: memory
        )
        let cursorDown = try readInteger(
            size: 8,
            from: commandBuffer + 0x18,
            memory: memory
        )
        let reservedDwords = try readInteger(
            size: 4,
            from: commandBuffer + 0x30,
            memory: memory
        )
        guard cursorDown >= cursorUp else { return nil }
        let availableDwords = (cursorDown - cursorUp) / 4
        guard availableDwords > reservedDwords,
              count <= availableDwords - reservedDwords else {
            return nil
        }
        try writeInteger(
            cursorUp + count * 4,
            size: 8,
            to: commandBuffer + 0x10,
            memory: &memory
        )
        return cursorUp
    }

    private func agcPM4Header(
        lengthDwords: UInt64,
        opcode: UInt64,
        register: UInt64
    ) -> UInt64 {
        0xC000_0000 |
            (((lengthDwords - 2) & 0x3FFF) << 16) |
            ((opcode & 0xFF) << 8) |
            ((register & 0x3F) << 2)
    }

    private func allocateAGCRegisterDefaults(
        groups: [AGCRegisterDefaultGroup],
        cxTableLength: UInt64,
        shTableLength: UInt64,
        ucTableLength: UInt64,
        memory: inout SparseVirtualMemory,
        heapCursor: inout UInt64,
        allocations: inout [UInt64: UInt64]
    ) throws -> UInt64 {
        func align(_ value: UInt64, to alignment: UInt64) -> UInt64 {
            (value + alignment - 1) & ~(alignment - 1)
        }
        let cxTableOffset: UInt64 = 0x40
        let shTableOffset = cxTableOffset + cxTableLength * 8
        let ucTableOffset = shTableOffset + shTableLength * 8
        let typesOffset = align(ucTableOffset + ucTableLength * 8, to: 4)
        let registerBlocksOffset = align(typesOffset + UInt64(groups.count) * 12, to: 8)
        let blobLength = registerBlocksOffset + UInt64(groups.count) * 128
        let address = allocateGuestMemory(
            size: blobLength,
            alignment: 0x1000,
            heapCursor: &heapCursor,
            allocations: &allocations
        )
        guard address != 0 else { return 0 }
        try memory.write(Data(count: Int(blobLength)), at: address)
        try writeInteger(address + cxTableOffset, size: 8, to: address, memory: &memory)
        try writeInteger(address + shTableOffset, size: 8, to: address + 0x08, memory: &memory)
        try writeInteger(address + ucTableOffset, size: 8, to: address + 0x10, memory: &memory)
        try writeInteger(address + typesOffset, size: 8, to: address + 0x30, memory: &memory)
        try writeInteger(UInt64(groups.count), size: 4, to: address + 0x38, memory: &memory)

        for (groupIndex, group) in groups.enumerated() {
            let tableOffset: UInt64
            let tableLength: UInt64
            switch group.space {
            case 0: (tableOffset, tableLength) = (cxTableOffset, cxTableLength)
            case 1: (tableOffset, tableLength) = (shTableOffset, shTableLength)
            case 2: (tableOffset, tableLength) = (ucTableOffset, ucTableLength)
            default: return 0
            }
            guard group.index < tableLength, group.registers.count <= 16 else { return 0 }
            let blockOffset = registerBlocksOffset + UInt64(groupIndex) * 128
            try writeInteger(
                address + blockOffset,
                size: 8,
                to: address + tableOffset + group.index * 8,
                memory: &memory
            )
            let typeEntry = address + typesOffset + UInt64(groupIndex) * 12
            try writeInteger(group.type, size: 4, to: typeEntry, memory: &memory)
            try writeInteger(
                group.index * 4 + group.space,
                size: 4,
                to: typeEntry + 4,
                memory: &memory
            )
            for (registerIndex, register) in group.registers.enumerated() {
                let registerAddress = address + blockOffset + UInt64(registerIndex) * 8
                try writeInteger(register.offset, size: 4, to: registerAddress, memory: &memory)
                try writeInteger(register.value, size: 4, to: registerAddress + 4, memory: &memory)
            }
        }
        return address
    }

    /// A joined thread is on another guest thread's startup critical path.
    /// Prefer it while it is runnable, but let it park normally on waits so
    /// workers it depends on can still make progress.
    private func dequeueNextReadyContext(
        from readyContexts: inout [RunnableGuestContext],
        joinWaiters _: [UInt64: [GuestJoinWaiter]]
    ) -> RunnableGuestContext {
        return readyContexts.removeFirst()
    }

    /// Give the title's active content loader three out of every four runnable
    /// quanta during startup. The fourth remains round-robin worker time so the
    /// loader cannot starve engine services it depends on.
    private func dequeueNextReadyContext(
        from readyContexts: inout [RunnableGuestContext],
        preferredHandle: UInt64?,
        priorityStreak: inout Int
    ) -> RunnableGuestContext {
        guard let preferredHandle,
              let preferredIndex = readyContexts.firstIndex(where: {
                  $0.threadHandle == preferredHandle
              }) else {
            priorityStreak = 0
            return readyContexts.removeFirst()
        }
        if priorityStreak < 3 {
            priorityStreak += 1
            return readyContexts.remove(at: preferredIndex)
        }
        if let workerIndex = readyContexts.firstIndex(where: {
            $0.threadHandle != preferredHandle
        }) {
            priorityStreak = 0
            return readyContexts.remove(at: workerIndex)
        }
        priorityStreak += 1
        return readyContexts.remove(at: preferredIndex)
    }

    private func execute(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory,
        interceptedImports: inout Int,
        importSymbolsByIndex: [Int: String],
        recentImports: inout [String],
        importCounts: inout [String: Int],
        runtimeEvents: inout [String],
        heapCursor: inout UInt64,
        allocations: inout [UInt64: UInt64],
        openFiles: inout [UInt64: GuestOpenFile],
        runtimeObjects: inout [String: UInt64],
        readyContexts: inout [RunnableGuestContext],
        sleepingContexts: inout [SleepingGuestContext],
        mutexStates: inout [UInt64: GuestMutexState],
        mutexWaiters: inout [UInt64: [GuestMutexWaiter]],
        currentInstruction: Int,
        activeThreadHandle: inout UInt64,
        threadReturnValues: inout [UInt64: UInt64],
        joinWaiters: inout [UInt64: [GuestJoinWaiter]],
        guestThreadCount: inout Int,
        contextSwitchCount: inout Int,
        nextThreadStackTop: inout UInt64,
        nextThreadTLSBlock: inout UInt64
    ) throws -> ARMExecutionStopReason? {
        let operands = instruction.operands
        let mnemonic = instruction.mnemonic.hasPrefix("lock ")
            ? String(instruction.mnemonic.dropFirst(5))
            : instruction.mnemonic
        state.rip = instruction.nextAddress

        if instruction.address == 0x000000080011F500,
           instruction.text == "push rbp" {
            let variant = state.readRegister("rdi")
            let type = try readInteger(size: 1, from: variant, memory: memory)
            if !(5...7).contains(type),
               !runtimeEvents.contains(where: {
                   $0.hasPrefix("numeric variant mismatch:")
               }) {
                var detail = "numeric variant mismatch: type=\(type) at \(variant.hexadecimal)"
                if type == 2 {
                    var remainingNodes = 32
                    detail += " value=" + (try variantDiagnosticSummary(
                        at: variant,
                        depth: 3,
                        remainingNodes: &remainingNodes,
                        memory: memory
                    ))
                }
                var neighbors: [String] = []
                for offset in -10...3 {
                    let candidate = offset < 0
                        ? variant - UInt64(-offset * 16)
                        : variant + UInt64(offset * 16)
                    var remainingNodes = 16
                    if let summary = try? variantDiagnosticSummary(
                        at: candidate,
                        depth: 1,
                        remainingNodes: &remainingNodes,
                        memory: memory
                    ) {
                        neighbors.append("\(offset):\(summary)")
                    }
                }
                detail += " neighbors=[\(neighbors.joined(separator: ";"))]"
                let callerFrame = state.readRegister("rbp")
                if callerFrame >= 0x80 {
                    var remainingNodes = 96
                    if let callerInput = try? variantDiagnosticSummary(
                        at: callerFrame - 0x80,
                        depth: 4,
                        remainingNodes: &remainingNodes,
                        memory: memory
                    ) {
                        detail += " callerInput=\(callerInput)"
                    }
                }
                recordRuntimeEvent(detail, events: &runtimeEvents)
            }
        }

        if instruction.address == 0x000000080012DBD8,
           instruction.text == "call 0x8002e6610",
           !runtimeEvents.contains(where: { $0.hasPrefix("JSON double before validation:") }) {
            let output = state.readRegister("rax")
            let bytes = try state.readVectorRegister("xmm0", byteCount: 8)
            var bits: UInt64 = 0
            for index in 0..<bytes.count {
                bits |= UInt64(bytes[index]) << UInt64(index * 8)
            }
            let type = try readInteger(size: 1, from: output, memory: memory)
            let payload = try readInteger(size: 8, from: output + 8, memory: memory)
            recordRuntimeEvent(
                "JSON double before validation: value=\(Double(bitPattern: bits)) " +
                    "type=\(type) payload=\(payload.hexadecimal)",
                events: &runtimeEvents
            )
        }

        if instruction.address == 0x000000080012DBE5,
           !runtimeEvents.contains(where: { $0.hasPrefix("JSON double after validation:") }) {
            let output = try readInteger(
                size: 8,
                from: state.readRegister("rbp") - 0xE8,
                memory: memory
            )
            let type = try readInteger(size: 1, from: output, memory: memory)
            let payload = try readInteger(size: 8, from: output + 8, memory: memory)
            recordRuntimeEvent(
                "JSON double after validation: type=\(type) payload=\(payload.hexadecimal)",
                events: &runtimeEvents
            )
        }

        if instruction.address == 0x000000080012E46C {
            let output = try readInteger(
                size: 8,
                from: state.readRegister("rbp") - 0xE8,
                memory: memory
            )
            let type = try readInteger(size: 1, from: output, memory: memory)
            if type == 7,
               !runtimeEvents.contains(where: { $0.hasPrefix("JSON double callback:") }) {
                let callbackObject = state.readRegister("rdi")
                let vtable = try readInteger(size: 8, from: callbackObject, memory: memory)
                let target = try readInteger(size: 8, from: vtable + 0x10, memory: memory)
                recordRuntimeEvent(
                    "JSON double callback: object=\(callbackObject.hexadecimal) " +
                        "target=\(target.hexadecimal) output=\(output.hexadecimal)",
                    events: &runtimeEvents
                )
                if stopAfterFirstJSONDouble {
                    return .halted("diagnostic stop after first JSON double callback")
                }
            }
        }

        if jsonTokenEntryFastPathEnabled,
           let skippedByteCount = try executeJSONTokenEntryIfPresent(
            instruction,
            state: &state,
            memory: &memory
        ) {
            let event = "ARM hot path: native JSON token entry"
            if skippedByteCount >= 0, !runtimeEvents.contains(event) {
                recordRuntimeEvent(event, events: &runtimeEvents)
            }
            if state.rip == instruction.address + 0x77 {
                runtimeObjects["json.parser.reachedEOF"] = 1
                let eofEvent = "JSON parser reached end of data.js"
                if !runtimeEvents.contains(eofEvent) {
                    recordRuntimeEvent(eofEvent, events: &runtimeEvents)
                }
            }
            return nil
        }

        if jsonNumberFastPathEnabled,
           let digitCount = try executeJSONNumberRunIfPresent(
            instruction,
            state: &state,
            memory: &memory
        ) {
            let event = "ARM hot path: native JSON number scan"
            if digitCount > 0, !runtimeEvents.contains(event) {
                recordRuntimeEvent(event, events: &runtimeEvents)
            }
            return nil
        }

        if jsonTokenReturnFastPathEnabled,
           try executeJSONTokenReturnIfPresent(
            instruction,
            state: &state,
            memory: &memory
        ) {
            let event = "ARM hot path: native JSON token return"
            if !runtimeEvents.contains(event) {
                recordRuntimeEvent(event, events: &runtimeEvents)
            }
            return nil
        }

        if variantMoveFastPathEnabled,
           let variantCount = try executeVariantMoveRunIfPresent(
            instruction,
            state: &state,
            memory: &memory
        ) {
            let event = "ARM hot path: native variant move run"
            if variantCount > 0, !runtimeEvents.contains(event) {
                recordRuntimeEvent(event, events: &runtimeEvents)
            }
            return nil
        }

        if variantDestructionFastPathsEnabled,
           let nodeCount = try executeVariantDestructionRunIfPresent(
            instruction,
            state: &state,
            memory: &memory
        ) {
            let event = "ARM hot path: native variant destruction run"
            if nodeCount > 0, !runtimeEvents.contains(event) {
                recordRuntimeEvent(event, events: &runtimeEvents)
            }
            return nil
        }

        if variantDestructionFastPathsEnabled,
           let nodeCount = try executeVariantDestructionIfPresent(
            instruction,
            state: &state,
            memory: &memory
        ) {
            let event = "ARM hot path: native variant destruction"
            if nodeCount > 0, !runtimeEvents.contains(event) {
                recordRuntimeEvent(event, events: &runtimeEvents)
            }
            return nil
        }

        if let nopCount = executeNOPRunIfPresent(
            instruction,
            state: &state,
            memory: memory
        ) {
            let event = "ARM hot path: coalesced x86 NOP padding"
            if nopCount > 1, !runtimeEvents.contains(event) {
                recordRuntimeEvent(event, events: &runtimeEvents)
            }
            return nil
        }

        if let tableEntryCount = try executeShaderBindingTableAllocationIfPresent(
            instruction,
            state: &state,
            memory: &memory,
            heapCursor: &heapCursor,
            allocations: &allocations
        ) {
            let event = "ARM hot path: allocated \(tableEntryCount)-entry shader binding table"
            if !runtimeEvents.contains(event) {
                recordRuntimeEvent(event, events: &runtimeEvents)
            }
            return nil
        }

        if let floatCount = try executeFloatClampLoopIfPresent(
            instruction,
            state: &state,
            memory: &memory
        ) {
            let event = "ARM hot path: clamped \(floatCount) float samples"
            if !runtimeEvents.contains(event) {
                recordRuntimeEvent(event, events: &runtimeEvents)
            }
            return nil
        }

        if let byteCount = try executePNGPaethScanlineLoopIfPresent(
            instruction,
            state: &state,
            memory: &memory
        ) {
            if !runtimeEvents.contains(where: { $0.hasPrefix("ARM hot path: PNG Paeth") }) {
                recordRuntimeEvent(
                    "ARM hot path: PNG Paeth scanlines (first \(byteCount) bytes)",
                    events: &runtimeEvents
                )
            }
            return nil
        }

        if let pixelCount = try executeRGBA8PremultiplicationLoopIfPresent(
            instruction,
            state: &state,
            memory: &memory
        ) {
            recordRuntimeEvent(
                "ARM hot path: premultiplied \(pixelCount) RGBA8 pixels",
                events: &runtimeEvents
            )
            return nil
        }

        switch mnemonic {
        case "nop", "endbr64", "pause", "lfence", "mfence", "sfence", "vzeroupper", "vzeroall":
            return nil
        case "xorps", "xorpd", "pxor", "vxorps", "vxorpd", "vpxor", "vpxord", "vpxorq":
            let sourceStart = operands.count == 3 ? 1 : 0
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let lhs = try readBytes(
                operands[sourceStart],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let rhs = try readBytes(
                operands[sourceStart + 1],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let count = max(operands[0].size, min(lhs.count, rhs.count))
            var result = Data(repeating: 0, count: count)
            for index in 0..<min(count, min(lhs.count, rhs.count)) {
                result[index] = lhs[index] ^ rhs[index]
            }
            try writeBytes(
                result,
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "pand", "por", "pandn", "vpand", "vpor", "vpandn",
             "vpandd", "vpandq", "vpord", "vporq", "vpandnd", "vpandnq",
             "andps", "andpd", "orps", "orpd", "andnps", "andnpd",
             "vandps", "vandpd", "vorps", "vorpd", "vandnps", "vandnpd":
            let sourceStart = operands.count == 3 ? 1 : 0
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let lhs = try readBytes(operands[sourceStart], instruction: instruction, state: state, memory: memory)
            let rhs = try readBytes(operands[sourceStart + 1], instruction: instruction, state: state, memory: memory)
            let count = operands[0].size
            var result = Data(repeating: 0, count: count)
            for index in 0..<min(count, min(lhs.count, rhs.count)) {
                if mnemonic.contains("andn") {
                    result[index] = ~lhs[index] & rhs[index]
                } else if mnemonic.contains("and") {
                    result[index] = lhs[index] & rhs[index]
                } else {
                    result[index] = lhs[index] | rhs[index]
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "pcmpeqb", "pcmpeqw", "pcmpeqd", "pcmpeqq",
             "vpcmpeqb", "vpcmpeqw", "vpcmpeqd", "vpcmpeqq",
             "pcmpgtb", "pcmpgtw", "pcmpgtd", "pcmpgtq",
             "vpcmpgtb", "vpcmpgtw", "vpcmpgtd", "vpcmpgtq":
            let sourceStart = operands.count == 3 ? 1 : 0
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let lhs = try readBytes(operands[sourceStart], instruction: instruction, state: state, memory: memory)
            let rhs = try readBytes(operands[sourceStart + 1], instruction: instruction, state: state, memory: memory)
            let elementSize: Int
            switch mnemonic.last {
            case "b": elementSize = 1
            case "w": elementSize = 2
            case "d": elementSize = 4
            default: elementSize = 8
            }
            let byteCount = operands[0].size
            var result = Data(repeating: 0, count: byteCount)
            for offset in stride(from: 0, to: byteCount, by: elementSize)
                where offset + elementSize <= lhs.count && offset + elementSize <= rhs.count {
                let matches: Bool
                if mnemonic.contains("cmpgt") {
                    var lhsBits: UInt64 = 0
                    var rhsBits: UInt64 = 0
                    for byte in 0..<elementSize {
                        lhsBits |= UInt64(lhs[offset + byte]) << UInt64(byte * 8)
                        rhsBits |= UInt64(rhs[offset + byte]) << UInt64(byte * 8)
                    }
                    let shift = UInt64(64 - elementSize * 8)
                    let lhsSigned = Int64(bitPattern: lhsBits << shift) >> shift
                    let rhsSigned = Int64(bitPattern: rhsBits << shift) >> shift
                    matches = lhsSigned > rhsSigned
                } else {
                    matches = lhs[offset..<(offset + elementSize)]
                        .elementsEqual(rhs[offset..<(offset + elementSize)])
                }
                if matches {
                    result.replaceSubrange(
                        offset..<(offset + elementSize),
                        with: repeatElement(UInt8.max, count: elementSize)
                    )
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "paddb", "paddw", "paddd", "paddq", "psubb", "psubw", "psubd", "psubq",
             "vpaddb", "vpaddw", "vpaddd", "vpaddq", "vpsubb", "vpsubw", "vpsubd", "vpsubq":
            let sourceStart = operands.count == 3 ? 1 : 0
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let lhs = try readBytes(operands[sourceStart], instruction: instruction, state: state, memory: memory)
            let rhs = try readBytes(operands[sourceStart + 1], instruction: instruction, state: state, memory: memory)
            let elementSize: Int
            switch mnemonic.last {
            case "b": elementSize = 1
            case "w": elementSize = 2
            case "d": elementSize = 4
            default: elementSize = 8
            }
            let elementMask = mask(forByteCount: elementSize)
            var result = Data(repeating: 0, count: operands[0].size)
            for offset in stride(from: 0, to: result.count, by: elementSize)
                where offset + elementSize <= lhs.count && offset + elementSize <= rhs.count {
                var left: UInt64 = 0
                var right: UInt64 = 0
                for byte in 0..<elementSize {
                    left |= UInt64(lhs[offset + byte]) << UInt64(byte * 8)
                    right |= UInt64(rhs[offset + byte]) << UInt64(byte * 8)
                }
                let value = mnemonic.contains("sub")
                    ? left &- right
                    : left &+ right
                for byte in 0..<elementSize {
                    result[offset + byte] = UInt8(
                        truncatingIfNeeded: (value & elementMask) >> UInt64(byte * 8)
                    )
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "pmulld", "vpmulld":
            let sourceStart = operands.count == 3 ? 1 : 0
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let lhs = try readBytes(
                operands[sourceStart],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let rhs = try readBytes(
                operands[sourceStart + 1],
                instruction: instruction,
                state: state,
                memory: memory
            )
            var result = Data(repeating: 0, count: operands[0].size)
            for offset in stride(from: 0, to: result.count, by: 4)
                where offset + 4 <= lhs.count && offset + 4 <= rhs.count {
                var left: UInt32 = 0
                var right: UInt32 = 0
                for byte in 0..<4 {
                    left |= UInt32(lhs[offset + byte]) << UInt32(byte * 8)
                    right |= UInt32(rhs[offset + byte]) << UInt32(byte * 8)
                }
                let product = left &* right
                for byte in 0..<4 {
                    result[offset + byte] = UInt8(
                        truncatingIfNeeded: product >> UInt32(byte * 8)
                    )
                }
            }
            try writeBytes(
                result,
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "movaps", "movups", "movapd", "movupd", "movdqa", "movdqu",
             "vmovaps", "vmovups", "vmovapd", "vmovupd", "vmovdqa", "vmovdqu",
             "vmovdqa32", "vmovdqa64", "vmovdqu8", "vmovdqu16", "vmovdqu32", "vmovdqu64",
             "movd", "movq", "vmovd", "vmovq":
            try requireOperands(operands, count: 2, instruction: instruction)
            let bytes = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            try writeBytes(bytes, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "movss", "movsd", "vmovss", "vmovsd":
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            if operands.count == 2 {
                let bytes = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
                try writeBytes(bytes, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            } else {
                var merged = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
                let scalar = try readBytes(operands[2], instruction: instruction, state: state, memory: memory)
                if merged.count < operands[0].size {
                    merged.append(Data(repeating: 0, count: operands[0].size - merged.count))
                }
                for index in 0..<min(scalar.count, merged.count) { merged[index] = scalar[index] }
                try writeBytes(merged, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            }
        case "cvtsi2ss", "cvtsi2sd", "vcvtsi2ss", "vcvtsi2sd",
             "cvtusi2ss", "cvtusi2sd", "vcvtusi2ss", "vcvtusi2sd":
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let baseIndex = operands.count == 3 ? 1 : 0
            let sourceIndex = operands.count == 3 ? 2 : 1
            var result = try readBytes(operands[baseIndex], instruction: instruction, state: state, memory: memory)
            if result.count < operands[0].size {
                result.append(Data(repeating: 0, count: operands[0].size - result.count))
            }
            let source = try read(operands[sourceIndex], instruction: instruction, state: state, memory: memory)
            let unsigned = mnemonic.contains("cvtusi")
            let scalarBytes: Data
            if mnemonic.hasSuffix("ss") {
                let value: Float
                if unsigned {
                    value = Float(source)
                } else if operands[sourceIndex].size == 4 {
                    value = Float(Int32(bitPattern: UInt32(truncatingIfNeeded: source)))
                } else {
                    value = Float(Int64(bitPattern: source))
                }
                var bits = value.bitPattern.littleEndian
                scalarBytes = Data(bytes: &bits, count: 4)
            } else {
                let value: Double
                if unsigned {
                    value = Double(source)
                } else if operands[sourceIndex].size == 4 {
                    value = Double(Int32(bitPattern: UInt32(truncatingIfNeeded: source)))
                } else {
                    value = Double(Int64(bitPattern: source))
                }
                var bits = value.bitPattern.littleEndian
                scalarBytes = Data(bytes: &bits, count: 8)
            }
            result.replaceSubrange(0..<scalarBytes.count, with: scalarBytes)
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "cvtss2sd", "cvtsd2ss", "vcvtss2sd", "vcvtsd2ss":
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let baseIndex = operands.count == 3 ? 1 : 0
            let sourceIndex = operands.count == 3 ? 2 : 1
            var result = try readBytes(
                operands[baseIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let source = try readBytes(
                operands[sourceIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            if result.count < operands[0].size {
                result.append(Data(repeating: 0, count: operands[0].size - result.count))
            }
            if mnemonic.contains("ss2sd") {
                var floatBits: UInt32 = 0
                for byte in 0..<min(4, source.count) {
                    floatBits |= UInt32(source[byte]) << UInt32(byte * 8)
                }
                var doubleBits = Double(Float(bitPattern: floatBits)).bitPattern.littleEndian
                let converted = Data(bytes: &doubleBits, count: 8)
                result.replaceSubrange(0..<8, with: converted)
            } else {
                var doubleBits: UInt64 = 0
                for byte in 0..<min(8, source.count) {
                    doubleBits |= UInt64(source[byte]) << UInt64(byte * 8)
                }
                var floatBits = Float(Double(bitPattern: doubleBits)).bitPattern.littleEndian
                let converted = Data(bytes: &floatBits, count: 4)
                result.replaceSubrange(0..<4, with: converted)
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "cvtpd2ps", "vcvtpd2ps":
            try requireOperands(operands, count: 2, instruction: instruction)
            let source = try readBytes(
                operands[1],
                instruction: instruction,
                state: state,
                memory: memory
            )
            var result = Data(repeating: 0, count: operands[0].size)
            let laneCount = min(source.count / 8, result.count / 4)
            for lane in 0..<laneCount {
                var doubleBits: UInt64 = 0
                for byte in 0..<8 {
                    doubleBits |= UInt64(source[lane * 8 + byte]) << UInt64(byte * 8)
                }
                var floatBits = Float(Double(bitPattern: doubleBits)).bitPattern.littleEndian
                let converted = Data(bytes: &floatBits, count: 4)
                let destinationOffset = lane * 4
                result.replaceSubrange(
                    destinationOffset..<(destinationOffset + 4),
                    with: converted
                )
            }
            try writeBytes(
                result,
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "cvtdq2ps", "vcvtdq2ps", "cvtps2dq", "vcvtps2dq",
             "cvttps2dq", "vcvttps2dq":
            try requireOperands(operands, count: 2, instruction: instruction)
            let source = try readBytes(
                operands[1],
                instruction: instruction,
                state: state,
                memory: memory
            )
            var result = Data(repeating: 0, count: operands[0].size)
            let laneCount = min(source.count, result.count) / 4
            for lane in 0..<laneCount {
                let offset = lane * 4
                var sourceBits: UInt32 = 0
                for byte in 0..<4 {
                    sourceBits |= UInt32(source[offset + byte]) << UInt32(byte * 8)
                }
                let outputBits: UInt32
                if mnemonic.contains("dq2ps") {
                    outputBits = Float(Int32(bitPattern: sourceBits)).bitPattern
                } else {
                    let sourceValue = Float(bitPattern: sourceBits)
                    let rounded = sourceValue.rounded(
                        mnemonic.contains("cvttps") ? .towardZero : .toNearestOrEven
                    )
                    if !rounded.isFinite ||
                        rounded < Float(Int32.min) ||
                        rounded >= 2_147_483_648 {
                        outputBits = 0x8000_0000
                    } else {
                        outputBits = UInt32(bitPattern: Int32(rounded))
                    }
                }
                for byte in 0..<4 {
                    result[offset + byte] = UInt8(
                        truncatingIfNeeded: outputBits >> UInt32(byte * 8)
                    )
                }
            }
            try writeBytes(
                result,
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "roundss", "roundsd", "vroundss", "vroundsd":
            let isVEX = mnemonic.hasPrefix("v")
            let expectedCount = isVEX ? 4 : 3
            try requireOperands(operands, count: expectedCount, instruction: instruction)
            let baseIndex = isVEX ? 1 : 0
            let sourceIndex = isVEX ? 2 : 1
            let immediateIndex = isVEX ? 3 : 2
            var result = try readBytes(
                operands[baseIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let source = try readBytes(
                operands[sourceIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let immediate = try read(
                operands[immediateIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            if result.count < operands[0].size {
                result.append(Data(repeating: 0, count: operands[0].size - result.count))
            }
            let roundingRule: FloatingPointRoundingRule = switch immediate & 0x3 {
            case 1: .down
            case 2: .up
            case 3: .towardZero
            default: .toNearestOrEven
            }
            if mnemonic.hasSuffix("ss") {
                var bits: UInt32 = 0
                for byte in 0..<min(4, source.count) {
                    bits |= UInt32(source[byte]) << UInt32(byte * 8)
                }
                var roundedBits = Float(bitPattern: bits)
                    .rounded(roundingRule)
                    .bitPattern
                    .littleEndian
                result.replaceSubrange(0..<4, with: Data(bytes: &roundedBits, count: 4))
            } else {
                var bits: UInt64 = 0
                for byte in 0..<min(8, source.count) {
                    bits |= UInt64(source[byte]) << UInt64(byte * 8)
                }
                var roundedBits = Double(bitPattern: bits)
                    .rounded(roundingRule)
                    .bitPattern
                    .littleEndian
                result.replaceSubrange(0..<8, with: Data(bytes: &roundedBits, count: 8))
            }
            try writeBytes(
                result,
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "cvttss2si", "cvttsd2si", "vcvttss2si", "vcvttsd2si":
            try requireOperands(operands, count: 2, instruction: instruction)
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let isDouble = mnemonic.contains("sd2si")
            let scalarByteCount = isDouble ? 8 : 4
            var bits: UInt64 = 0
            for byte in 0..<min(scalarByteCount, source.count) {
                bits |= UInt64(source[byte]) << UInt64(byte * 8)
            }
            let value = isDouble
                ? Double(bitPattern: bits)
                : Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
            let lowerBound = operands[0].size == 4
                ? Double(Int32.min)
                : -9_223_372_036_854_775_808.0
            let upperBound = operands[0].size == 4
                ? 2_147_483_648.0
                : 9_223_372_036_854_775_808.0
            let output: UInt64
            if !value.isFinite || value < lowerBound || value >= upperBound {
                output = operands[0].size == 4 ? 0x8000_0000 : 0x8000_0000_0000_0000
            } else {
                output = UInt64(bitPattern: Int64(value.rounded(.towardZero)))
            }
            try write(
                output,
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "addss", "addsd", "subss", "subsd", "mulss", "mulsd", "divss", "divsd",
             "minss", "minsd", "maxss", "maxsd",
             "vaddss", "vaddsd", "vsubss", "vsubsd", "vmulss", "vmulsd", "vdivss", "vdivsd",
             "vminss", "vminsd", "vmaxss", "vmaxsd":
            let sourceStart = operands.count == 3 ? 1 : 0
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let lhs = try readBytes(operands[sourceStart], instruction: instruction, state: state, memory: memory)
            let rhs = try readBytes(operands[sourceStart + 1], instruction: instruction, state: state, memory: memory)
            var result = lhs
            if result.count < operands[0].size {
                result.append(Data(repeating: 0, count: operands[0].size - result.count))
            }
            let isDouble = mnemonic.hasSuffix("sd")
            let scalarByteCount = isDouble ? 8 : 4
            var leftBits: UInt64 = 0
            var rightBits: UInt64 = 0
            for byte in 0..<scalarByteCount {
                leftBits |= UInt64(lhs[byte]) << UInt64(byte * 8)
                rightBits |= UInt64(rhs[byte]) << UInt64(byte * 8)
            }
            var outputBits: UInt64
            if isDouble {
                let left = Double(bitPattern: leftBits)
                let right = Double(bitPattern: rightBits)
                let output: Double
                if mnemonic.contains("add") { output = left + right }
                else if mnemonic.contains("sub") { output = left - right }
                else if mnemonic.contains("mul") { output = left * right }
                else if mnemonic.contains("div") { output = left / right }
                else if left.isNaN || right.isNaN || left == right { output = right }
                else if mnemonic.contains("min") { output = Swift.min(left, right) }
                else { output = Swift.max(left, right) }
                outputBits = output.bitPattern
            } else {
                let left = Float(bitPattern: UInt32(truncatingIfNeeded: leftBits))
                let right = Float(bitPattern: UInt32(truncatingIfNeeded: rightBits))
                let output: Float
                if mnemonic.contains("add") { output = left + right }
                else if mnemonic.contains("sub") { output = left - right }
                else if mnemonic.contains("mul") { output = left * right }
                else if mnemonic.contains("div") { output = left / right }
                else if left.isNaN || right.isNaN || left == right { output = right }
                else if mnemonic.contains("min") { output = Swift.min(left, right) }
                else { output = Swift.max(left, right) }
                outputBits = UInt64(output.bitPattern)
            }
            for byte in 0..<scalarByteCount {
                result[byte] = UInt8(truncatingIfNeeded: outputBits >> UInt64(byte * 8))
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "comiss", "ucomiss", "vcomiss", "vucomiss",
             "comisd", "ucomisd", "vcomisd", "vucomisd":
            try requireOperands(operands, count: 2, instruction: instruction)
            let lhs = try readBytes(operands[0], instruction: instruction, state: state, memory: memory)
            let rhs = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let isDouble = mnemonic.hasSuffix("sd")
            let scalarByteCount = isDouble ? 8 : 4
            var leftBits: UInt64 = 0
            var rightBits: UInt64 = 0
            for byte in 0..<scalarByteCount {
                leftBits |= UInt64(lhs[byte]) << UInt64(byte * 8)
                rightBits |= UInt64(rhs[byte]) << UInt64(byte * 8)
            }
            let unordered: Bool
            let equal: Bool
            let less: Bool
            if isDouble {
                let left = Double(bitPattern: leftBits)
                let right = Double(bitPattern: rightBits)
                unordered = left.isNaN || right.isNaN
                equal = left == right
                less = left < right
            } else {
                let left = Float(bitPattern: UInt32(truncatingIfNeeded: leftBits))
                let right = Float(bitPattern: UInt32(truncatingIfNeeded: rightBits))
                unordered = left.isNaN || right.isNaN
                equal = left == right
                less = left < right
            }
            state.setFlag(.zero, unordered || equal)
            state.setFlag(.parity, unordered)
            state.setFlag(.carry, unordered || less)
            state.setFlag(.overflow, false)
            state.setFlag(.sign, false)
            state.setFlag(.auxiliary, false)
        case "addps", "addpd", "subps", "subpd", "mulps", "mulpd", "divps", "divpd",
             "minps", "minpd", "maxps", "maxpd", "vaddps", "vaddpd", "vsubps", "vsubpd",
             "vmulps", "vmulpd", "vdivps", "vdivpd", "vminps", "vminpd", "vmaxps", "vmaxpd":
            let sourceStart = operands.count == 3 ? 1 : 0
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let lhs = try readBytes(operands[sourceStart], instruction: instruction, state: state, memory: memory)
            let rhs = try readBytes(operands[sourceStart + 1], instruction: instruction, state: state, memory: memory)
            let elementSize = mnemonic.hasSuffix("pd") ? 8 : 4
            var result = Data(repeating: 0, count: operands[0].size)
            for offset in stride(from: 0, to: result.count, by: elementSize)
                where offset + elementSize <= lhs.count && offset + elementSize <= rhs.count {
                var leftBits: UInt64 = 0
                var rightBits: UInt64 = 0
                for byte in 0..<elementSize {
                    leftBits |= UInt64(lhs[offset + byte]) << UInt64(byte * 8)
                    rightBits |= UInt64(rhs[offset + byte]) << UInt64(byte * 8)
                }
                let outputBits: UInt64
                if elementSize == 8 {
                    let left = Double(bitPattern: leftBits)
                    let right = Double(bitPattern: rightBits)
                    let output: Double
                    if mnemonic.contains("add") { output = left + right }
                    else if mnemonic.contains("sub") { output = left - right }
                    else if mnemonic.contains("mul") { output = left * right }
                    else if mnemonic.contains("div") { output = left / right }
                    else if left.isNaN || right.isNaN || left == right { output = right }
                    else if mnemonic.contains("min") { output = Swift.min(left, right) }
                    else { output = Swift.max(left, right) }
                    outputBits = output.bitPattern
                } else {
                    let left = Float(bitPattern: UInt32(truncatingIfNeeded: leftBits))
                    let right = Float(bitPattern: UInt32(truncatingIfNeeded: rightBits))
                    let output: Float
                    if mnemonic.contains("add") { output = left + right }
                    else if mnemonic.contains("sub") { output = left - right }
                    else if mnemonic.contains("mul") { output = left * right }
                    else if mnemonic.contains("div") { output = left / right }
                    else if left.isNaN || right.isNaN || left == right { output = right }
                    else if mnemonic.contains("min") { output = Swift.min(left, right) }
                    else { output = Swift.max(left, right) }
                    outputBits = UInt64(output.bitPattern)
                }
                for byte in 0..<elementSize {
                    result[offset + byte] = UInt8(truncatingIfNeeded: outputBits >> UInt64(byte * 8))
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "movlps", "vmovlps":
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            if operands.count == 3 {
                var result = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
                let low = try readBytes(operands[2], instruction: instruction, state: state, memory: memory)
                if result.count < 16 { result.append(Data(repeating: 0, count: 16 - result.count)) }
                result.replaceSubrange(0..<8, with: low.prefix(8))
                try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            } else if case .memory = operands[0].value {
                let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
                try writeBytes(
                    Data(source.prefix(8)),
                    to: operands[0],
                    instruction: instruction,
                    state: &state,
                    memory: &memory
                )
            } else {
                var result = try readBytes(operands[0], instruction: instruction, state: state, memory: memory)
                let low = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
                if result.count < 16 { result.append(Data(repeating: 0, count: 16 - result.count)) }
                result.replaceSubrange(0..<8, with: low.prefix(8))
                try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            }
        case "movhps", "vmovhps":
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            if operands.count == 3 {
                var result = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
                let high = try readBytes(operands[2], instruction: instruction, state: state, memory: memory)
                if result.count < 16 { result.append(Data(repeating: 0, count: 16 - result.count)) }
                result.replaceSubrange(8..<16, with: high.prefix(8))
                try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            } else if case .memory = operands[0].value {
                let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
                try writeBytes(
                    Data(source.dropFirst(8).prefix(8)),
                    to: operands[0],
                    instruction: instruction,
                    state: &state,
                    memory: &memory
                )
            } else {
                var result = try readBytes(operands[0], instruction: instruction, state: state, memory: memory)
                let high = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
                if result.count < 16 { result.append(Data(repeating: 0, count: 16 - result.count)) }
                result.replaceSubrange(8..<16, with: high.prefix(8))
                try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            }
        case "vpbroadcastb", "vpbroadcastw", "vpbroadcastd", "vpbroadcastq":
            try requireOperands(operands, count: 2, instruction: instruction)
            let elementSize: Int
            switch instruction.mnemonic.last {
            case "b": elementSize = 1
            case "w": elementSize = 2
            case "d": elementSize = 4
            default: elementSize = 8
            }
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let element = Data(source.prefix(elementSize))
            var result = Data()
            while result.count < operands[0].size { result.append(element) }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "vbroadcastss", "vbroadcastsd":
            try requireOperands(operands, count: 2, instruction: instruction)
            let elementSize = mnemonic.hasSuffix("ss") ? 4 : 8
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let element = Data(source.prefix(elementSize))
            var result = Data()
            while result.count < operands[0].size { result.append(element) }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "vbroadcastf128", "vbroadcasti128":
            try requireOperands(operands, count: 2, instruction: instruction)
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let lane = Data(source.prefix(16))
            var result = Data()
            while result.count < operands[0].size { result.append(lane) }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "vpsllvd", "vpsllvq", "vpsrlvd", "vpsrlvq", "vpsravd", "vpsravq":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let counts = try readBytes(operands[2], instruction: instruction, state: state, memory: memory)
            let elementSize = mnemonic.hasSuffix("d") ? 4 : 8
            let bitWidth = elementSize * 8
            var result = Data(repeating: 0, count: operands[0].size)
            for offset in stride(from: 0, to: result.count, by: elementSize)
                where offset + elementSize <= source.count && offset + elementSize <= counts.count {
                var value: UInt64 = 0
                var count: UInt64 = 0
                for byte in 0..<elementSize {
                    value |= UInt64(source[offset + byte]) << UInt64(byte * 8)
                    count |= UInt64(counts[offset + byte]) << UInt64(byte * 8)
                }
                let shifted: UInt64
                if mnemonic.contains("psllv") {
                    shifted = count >= UInt64(bitWidth) ? 0 : value << count
                } else if mnemonic.contains("psrlv") {
                    shifted = count >= UInt64(bitWidth) ? 0 : value >> count
                } else {
                    let effectiveCount = min(count, UInt64(bitWidth - 1))
                    let signed = Int64(bitPattern: signExtend(value, fromByteCount: elementSize))
                    shifted = UInt64(bitPattern: signed >> Int64(effectiveCount))
                }
                for byte in 0..<elementSize {
                    result[offset + byte] = UInt8(truncatingIfNeeded: shifted >> UInt64(byte * 8))
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "psllw", "pslld", "psllq", "vpsllw", "vpslld", "vpsllq",
             "psrlw", "psrld", "psrlq", "vpsrlw", "vpsrld", "vpsrlq",
             "psraw", "psrad", "psraq", "vpsraw", "vpsrad", "vpsraq":
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let sourceIndex = operands.count == 3 ? 1 : 0
            let countIndex = operands.count == 3 ? 2 : 1
            let source = try readBytes(operands[sourceIndex], instruction: instruction, state: state, memory: memory)
            // Register/memory shift counts are encoded as an XMM operand, but
            // Intel defines only its low 64 bits as the scalar count. Reading
            // it as a scalar operand incorrectly rejects the legal 16-byte
            // width before we can select those low bytes.
            let countBytes = try readBytes(
                operands[countIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            var count: UInt64 = 0
            for byte in 0..<min(8, countBytes.count) {
                count |= UInt64(countBytes[byte]) << UInt64(byte * 8)
            }
            let elementSize: Int
            switch mnemonic.last {
            case "w": elementSize = 2
            case "d": elementSize = 4
            default: elementSize = 8
            }
            let bitWidth = elementSize * 8
            var result = Data(repeating: 0, count: operands[0].size)
            for offset in stride(from: 0, to: result.count, by: elementSize)
                where offset + elementSize <= source.count {
                var value: UInt64 = 0
                for byte in 0..<elementSize {
                    value |= UInt64(source[offset + byte]) << UInt64(byte * 8)
                }
                let shifted: UInt64
                if mnemonic.contains("psll") {
                    shifted = count >= UInt64(bitWidth) ? 0 : value << count
                } else if mnemonic.contains("psrl") {
                    shifted = count >= UInt64(bitWidth) ? 0 : value >> count
                } else {
                    let effectiveCount = min(count, UInt64(bitWidth - 1))
                    let signedValue = Int64(bitPattern: signExtend(value, fromByteCount: elementSize))
                    shifted = UInt64(bitPattern: signedValue >> Int64(effectiveCount))
                }
                for byte in 0..<elementSize {
                    result[offset + byte] = UInt8(truncatingIfNeeded: shifted >> UInt64(byte * 8))
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "pslldq", "psrldq", "vpslldq", "vpsrldq":
            let sourceIndex = operands.count == 3 ? 1 : 0
            let immediateIndex = operands.count == 3 ? 2 : 1
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let source = try readBytes(
                operands[sourceIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let immediate = try read(
                operands[immediateIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let shift = min(Int(immediate), 16)
            var result = Data(repeating: 0, count: operands[0].size)
            for laneStart in stride(from: 0, to: result.count, by: 16) {
                let laneCount = min(16, result.count - laneStart)
                for byte in 0..<laneCount {
                    let sourceByte = mnemonic.contains("pslldq")
                        ? byte - shift
                        : byte + shift
                    if sourceByte >= 0,
                       sourceByte < laneCount,
                       laneStart + sourceByte < source.count {
                        result[laneStart + byte] = source[laneStart + sourceByte]
                    }
                }
            }
            try writeBytes(
                result,
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "palignr", "vpalignr":
            let sourceStart = operands.count == 4 ? 1 : 0
            let immediateIndex = operands.count == 4 ? 3 : 2
            guard operands.count == 3 || operands.count == 4 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let high = try readBytes(
                operands[sourceStart],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let low = try readBytes(
                operands[sourceStart + 1],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let shift = Int(try read(
                operands[immediateIndex],
                instruction: instruction,
                state: state,
                memory: memory
            ))
            var result = Data(repeating: 0, count: operands[0].size)
            for laneStart in stride(from: 0, to: result.count, by: 16) {
                let laneCount = min(16, result.count - laneStart)
                var concatenated = Data(repeating: 0, count: laneCount * 2)
                for byte in 0..<laneCount {
                    if laneStart + byte < low.count {
                        concatenated[byte] = low[laneStart + byte]
                    }
                    if laneStart + byte < high.count {
                        concatenated[laneCount + byte] = high[laneStart + byte]
                    }
                }
                for byte in 0..<laneCount where shift + byte < concatenated.count {
                    result[laneStart + byte] = concatenated[shift + byte]
                }
            }
            try writeBytes(
                result,
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case let conversion where conversion.hasPrefix("pmovzx") || conversion.hasPrefix("vpmovzx")
            || conversion.hasPrefix("pmovsx") || conversion.hasPrefix("vpmovsx"):
            try requireOperands(operands, count: 2, instruction: instruction)
            let suffix = conversion.suffix(2)
            let elementSize: (Character) -> Int = { character in
                switch character {
                case "b": 1
                case "w": 2
                case "d": 4
                default: 8
                }
            }
            guard let sourceKind = suffix.first, let destinationKind = suffix.last else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let sourceElementSize = elementSize(sourceKind)
            let destinationElementSize = elementSize(destinationKind)
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            var result = Data(repeating: 0, count: operands[0].size)
            let signed = conversion.contains("pmovsx")
            for element in 0..<(result.count / destinationElementSize) {
                let sourceOffset = element * sourceElementSize
                guard sourceOffset + sourceElementSize <= source.count else { break }
                var value: UInt64 = 0
                for byte in 0..<sourceElementSize {
                    value |= UInt64(source[sourceOffset + byte]) << UInt64(byte * 8)
                }
                if signed { value = signExtend(value, fromByteCount: sourceElementSize) }
                let destinationOffset = element * destinationElementSize
                for byte in 0..<destinationElementSize {
                    result[destinationOffset + byte] = UInt8(truncatingIfNeeded: value >> UInt64(byte * 8))
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "vinsertf128", "vinserti128":
            try requireOperands(operands, count: 4, instruction: instruction)
            var result = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let lane = try readBytes(operands[2], instruction: instruction, state: state, memory: memory)
            let immediate = try read(operands[3], instruction: instruction, state: state, memory: memory)
            if result.count < operands[0].size {
                result.append(Data(repeating: 0, count: operands[0].size - result.count))
            }
            let offset = Int(immediate & 1) * 16
            let copyCount = min(16, lane.count)
            if offset + copyCount <= result.count {
                result.replaceSubrange(offset..<(offset + copyCount), with: lane.prefix(copyCount))
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "vextractf128", "vextracti128":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let immediate = try read(operands[2], instruction: instruction, state: state, memory: memory)
            let offset = Int(immediate & 1) * 16
            guard offset + 16 <= source.count else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            try writeBytes(
                Data(source[offset..<(offset + 16)]),
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "packsswb", "packuswb", "packssdw", "packusdw",
             "vpacksswb", "vpackuswb", "vpackssdw", "vpackusdw":
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let sourceStart = operands.count == 3 ? 1 : 0
            let lhs = try readBytes(
                operands[sourceStart],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let rhs = try readBytes(
                operands[sourceStart + 1],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let inputElementSize = mnemonic.hasSuffix("dw") ? 4 : 2
            let outputElementSize = inputElementSize / 2
            let unsignedOutput = mnemonic.contains("packus")
            let signedMinimum = -(Int64(1) << Int64(outputElementSize * 8 - 1))
            let signedMaximum = (Int64(1) << Int64(outputElementSize * 8 - 1)) - 1
            let unsignedMaximum = (Int64(1) << Int64(outputElementSize * 8)) - 1
            var result = Data()
            for laneOffset in stride(from: 0, to: operands[0].size, by: 16) {
                for source in [lhs, rhs] {
                    for sourceOffset in stride(
                        from: laneOffset,
                        to: laneOffset + 16,
                        by: inputElementSize
                    ) where sourceOffset + inputElementSize <= source.count {
                        var bits: UInt64 = 0
                        for byte in 0..<inputElementSize {
                            bits |= UInt64(source[sourceOffset + byte]) << UInt64(byte * 8)
                        }
                        let signed = Int64(bitPattern: signExtend(bits, fromByteCount: inputElementSize))
                        let clamped = unsignedOutput
                            ? min(max(signed, 0), unsignedMaximum)
                            : min(max(signed, signedMinimum), signedMaximum)
                        let outputBits = UInt64(bitPattern: clamped)
                        for byte in 0..<outputElementSize {
                            result.append(UInt8(truncatingIfNeeded: outputBits >> UInt64(byte * 8)))
                        }
                    }
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "punpcklbw", "punpcklwd", "punpckldq", "punpcklqdq",
             "punpckhbw", "punpckhwd", "punpckhdq", "punpckhqdq",
             "vpunpcklbw", "vpunpcklwd", "vpunpckldq", "vpunpcklqdq",
             "vpunpckhbw", "vpunpckhwd", "vpunpckhdq", "vpunpckhqdq":
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let sourceStart = operands.count == 3 ? 1 : 0
            let lhs = try readBytes(
                operands[sourceStart],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let rhs = try readBytes(
                operands[sourceStart + 1],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let elementSize: Int
            if mnemonic.hasSuffix("bw") { elementSize = 1 }
            else if mnemonic.hasSuffix("wd") { elementSize = 2 }
            else if mnemonic.hasSuffix("qdq") { elementSize = 8 }
            else { elementSize = 4 }
            let highHalf = mnemonic.contains("punpckh")
            let elementsPerHalf = 8 / elementSize
            let firstElement = highHalf ? elementsPerHalf : 0
            var result = Data()
            for laneOffset in stride(from: 0, to: operands[0].size, by: 16) {
                for element in 0..<elementsPerHalf {
                    let offset = laneOffset + (firstElement + element) * elementSize
                    if offset + elementSize <= lhs.count {
                        result.append(lhs[offset..<(offset + elementSize)])
                    }
                    if offset + elementSize <= rhs.count {
                        result.append(rhs[offset..<(offset + elementSize)])
                    }
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "vunpcklpd", "vunpckhpd", "vunpcklps", "vunpckhps":
            try requireOperands(operands, count: 3, instruction: instruction)
            let lhs = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let rhs = try readBytes(operands[2], instruction: instruction, state: state, memory: memory)
            let elementSize = mnemonic.hasSuffix("pd") ? 8 : 4
            let elementsPerLane = 16 / elementSize
            let firstElement = mnemonic.contains("h") ? elementsPerLane / 2 : 0
            var result = Data()
            for laneOffset in stride(from: 0, to: operands[0].size, by: 16) {
                for element in 0..<(elementsPerLane / 2) {
                    let sourceOffset = laneOffset + (firstElement + element) * elementSize
                    if sourceOffset + elementSize <= lhs.count {
                        result.append(lhs[sourceOffset..<(sourceOffset + elementSize)])
                    }
                    if sourceOffset + elementSize <= rhs.count {
                        result.append(rhs[sourceOffset..<(sourceOffset + elementSize)])
                    }
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "vshufps", "vshufpd":
            try requireOperands(operands, count: 4, instruction: instruction)
            let lhs = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let rhs = try readBytes(operands[2], instruction: instruction, state: state, memory: memory)
            let immediate = try read(operands[3], instruction: instruction, state: state, memory: memory)
            let elementSize = mnemonic.hasSuffix("ps") ? 4 : 8
            let elementsPerLane = 16 / elementSize
            var result = Data()
            for laneOffset in stride(from: 0, to: operands[0].size, by: 16) {
                for outputIndex in 0..<elementsPerLane {
                    let fromLeft = outputIndex < elementsPerLane / 2
                    let source = fromLeft ? lhs : rhs
                    let selectorBits = elementSize == 4 ? 2 : 1
                    let selector = Int((immediate >> UInt64(outputIndex * selectorBits)) & UInt64(elementsPerLane - 1))
                    let sourceOffset = laneOffset + selector * elementSize
                    if sourceOffset + elementSize <= source.count {
                        result.append(source[sourceOffset..<(sourceOffset + elementSize)])
                    }
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "movshdup", "vmovshdup":
            try requireOperands(operands, count: 2, instruction: instruction)
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            var result = Data(repeating: 0, count: operands[0].size)
            for laneOffset in stride(from: 0, to: result.count, by: 16) {
                for outputElement in 0..<4 {
                    let sourceElement = (outputElement & ~1) + 1
                    let sourceOffset = laneOffset + sourceElement * 4
                    let destinationOffset = laneOffset + outputElement * 4
                    guard sourceOffset + 4 <= source.count,
                          destinationOffset + 4 <= result.count else { continue }
                    result.replaceSubrange(
                        destinationOffset..<(destinationOffset + 4),
                        with: source[sourceOffset..<(sourceOffset + 4)]
                    )
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "vpermilps", "vpermilpd":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let immediate = try read(operands[2], instruction: instruction, state: state, memory: memory)
            let elementSize = mnemonic.hasSuffix("pd") ? 8 : 4
            let elementsPerLane = 16 / elementSize
            let selectorBits = elementSize == 8 ? 1 : 2
            var result = Data()
            for laneOffset in stride(from: 0, to: operands[0].size, by: 16) {
                for outputElement in 0..<elementsPerLane {
                    let selector = Int(
                        (immediate >> UInt64(outputElement * selectorBits))
                            & UInt64(elementsPerLane - 1)
                    )
                    let offset = laneOffset + selector * elementSize
                    if offset + elementSize <= source.count {
                        result.append(source[offset..<(offset + elementSize)])
                    }
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "vpermq":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let immediate = try read(operands[2], instruction: instruction, state: state, memory: memory)
            var result = Data(repeating: 0, count: operands[0].size)
            for outputElement in 0..<min(4, result.count / 8) {
                let selector = Int((immediate >> UInt64(outputElement * 2)) & 3)
                let sourceOffset = selector * 8
                let destinationOffset = outputElement * 8
                guard sourceOffset + 8 <= source.count else { continue }
                result.replaceSubrange(
                    destinationOffset..<(destinationOffset + 8),
                    with: source[sourceOffset..<(sourceOffset + 8)]
                )
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "pshufd", "vpshufd":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let immediate = try read(operands[2], instruction: instruction, state: state, memory: memory)
            var result = Data()
            for laneOffset in stride(from: 0, to: operands[0].size, by: 16) {
                for outputElement in 0..<4 {
                    let selector = Int((immediate >> UInt64(outputElement * 2)) & 3)
                    let sourceOffset = laneOffset + selector * 4
                    if sourceOffset + 4 <= source.count {
                        result.append(source[sourceOffset..<(sourceOffset + 4)])
                    }
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "pblendw", "vpblendw", "pblendd", "vpblendd":
            guard operands.count == 3 || operands.count == 4 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let baseIndex = operands.count == 4 ? 1 : 0
            let sourceIndex = operands.count == 4 ? 2 : 1
            let immediateIndex = operands.count == 4 ? 3 : 2
            var result = try readBytes(
                operands[baseIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let source = try readBytes(
                operands[sourceIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let immediate = try read(
                operands[immediateIndex],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let elementSize = mnemonic.hasSuffix("w") ? 2 : 4
            if result.count < operands[0].size {
                result.append(Data(repeating: 0, count: operands[0].size - result.count))
            }
            for element in 0..<(operands[0].size / elementSize)
                where immediate & (UInt64(1) << UInt64(element & 7)) != 0 {
                let offset = element * elementSize
                if offset + elementSize <= source.count {
                    result.replaceSubrange(
                        offset..<(offset + elementSize),
                        with: source[offset..<(offset + elementSize)]
                    )
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "pshufb", "vpshufb":
            let sourceIndex = operands.count == 3 ? 1 : 0
            let selectorIndex = operands.count == 3 ? 2 : 1
            guard operands.count == 2 || operands.count == 3 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let source = try readBytes(operands[sourceIndex], instruction: instruction, state: state, memory: memory)
            let selectors = try readBytes(operands[selectorIndex], instruction: instruction, state: state, memory: memory)
            var result = Data(repeating: 0, count: operands[0].size)
            for laneOffset in stride(from: 0, to: result.count, by: 16) {
                for byte in 0..<16
                    where laneOffset + byte < result.count && laneOffset + byte < selectors.count {
                    let selector = selectors[laneOffset + byte]
                    if selector & 0x80 == 0 {
                        let sourceOffset = laneOffset + Int(selector & 0x0F)
                        if sourceOffset < source.count {
                            result[laneOffset + byte] = source[sourceOffset]
                        }
                    }
                }
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "vinsertps":
            try requireOperands(operands, count: 4, instruction: instruction)
            var result = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let source = try readBytes(operands[2], instruction: instruction, state: state, memory: memory)
            let immediate = try read(operands[3], instruction: instruction, state: state, memory: memory)
            if result.count < 16 { result.append(Data(repeating: 0, count: 16 - result.count)) }
            let sourceIndex = source.count <= 4 ? 0 : Int((immediate >> 6) & 3)
            let destinationIndex = Int((immediate >> 4) & 3)
            let sourceOffset = sourceIndex * 4
            if sourceOffset + 4 <= source.count {
                result.replaceSubrange(
                    (destinationIndex * 4)..<(destinationIndex * 4 + 4),
                    with: source[sourceOffset..<(sourceOffset + 4)]
                )
            }
            for lane in 0..<4 where immediate & (UInt64(1) << UInt64(lane)) != 0 {
                result.replaceSubrange((lane * 4)..<(lane * 4 + 4), with: repeatElement(UInt8(0), count: 4))
            }
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "pextrb", "pextrw", "pextrd", "pextrq",
             "vpextrb", "vpextrw", "vpextrd", "vpextrq":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try readBytes(operands[1], instruction: instruction, state: state, memory: memory)
            let immediate = try read(operands[2], instruction: instruction, state: state, memory: memory)
            let elementSize: Int
            switch mnemonic.last {
            case "b": elementSize = 1
            case "w": elementSize = 2
            case "d": elementSize = 4
            default: elementSize = 8
            }
            let elementCount = max(1, source.count / elementSize)
            let offset = Int(immediate % UInt64(elementCount)) * elementSize
            var value: UInt64 = 0
            for index in 0..<elementSize where offset + index < source.count {
                value |= UInt64(source[offset + index]) << UInt64(index * 8)
            }
            try write(value, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "pinsrb", "pinsrw", "pinsrd", "pinsrq",
             "vpinsrb", "vpinsrw", "vpinsrd", "vpinsrq":
            guard operands.count == 3 || operands.count == 4 else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let baseIndex = operands.count == 4 ? 1 : 0
            let sourceIndex = operands.count == 4 ? 2 : 1
            let immediateIndex = operands.count == 4 ? 3 : 2
            var result = try readBytes(operands[baseIndex], instruction: instruction, state: state, memory: memory)
            let source = try readBytes(operands[sourceIndex], instruction: instruction, state: state, memory: memory)
            let immediate = try read(operands[immediateIndex], instruction: instruction, state: state, memory: memory)
            let elementSize: Int
            switch mnemonic.last {
            case "b": elementSize = 1
            case "w": elementSize = 2
            case "d": elementSize = 4
            default: elementSize = 8
            }
            if result.count < operands[0].size {
                result.append(Data(repeating: 0, count: operands[0].size - result.count))
            }
            let elementCount = max(1, operands[0].size / elementSize)
            let offset = Int(immediate % UInt64(elementCount)) * elementSize
            result.replaceSubrange(offset..<(offset + elementSize), with: source.prefix(elementSize))
            try writeBytes(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "mov", "movabs":
            try requireOperands(operands, count: 2, instruction: instruction)
            let value = try read(operands[1], instruction: instruction, state: state, memory: memory)
            try write(value, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "movbe":
            try requireOperands(operands, count: 2, instruction: instruction)
            let value = try read(operands[1], instruction: instruction, state: state, memory: memory)
            let reversed = reverseBytes(value, size: operands[0].size)
            try write(reversed, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "bswap":
            try requireOperands(operands, count: 1, instruction: instruction)
            let value = try read(operands[0], instruction: instruction, state: state, memory: memory)
            try write(
                reverseBytes(value, size: operands[0].size),
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "lea":
            try requireOperands(operands, count: 2, instruction: instruction)
            guard case let .memory(memoryOperand) = operands[1].value else {
                throw ARMInterpreterError.invalidOperand(instruction.text)
            }
            let address = try effectiveAddress(
                memoryOperand,
                nextInstruction: instruction.nextAddress,
                state: state
            )
            try write(address, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "push":
            try requireOperands(operands, count: 1, instruction: instruction)
            var value = try read(operands[0], instruction: instruction, state: state, memory: memory)
            if case .immediate = operands[0].value, operands[0].size < 8 {
                value = signExtend(value, fromByteCount: operands[0].size)
            }
            try push(value, state: &state, memory: &memory)
        case "pop":
            try requireOperands(operands, count: 1, instruction: instruction)
            let value = try pop(state: &state, memory: memory)
            try write(value, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "pushfq":
            try push(state.flags, state: &state, memory: &memory)
        case "popfq":
            state.flags = try pop(state: &state, memory: memory)
        case "call":
            try requireOperands(operands, count: 1, instruction: instruction)
            let target = try read(operands[0], instruction: instruction, state: state, memory: memory)
            if let importIndex = try importStubIndex(at: target, memory: memory) {
                interceptedImports += 1
                let symbol = importSymbolsByIndex[Int(importIndex)]
                recordImport(
                    index: Int(importIndex),
                    symbol: symbol,
                    recentImports: &recentImports,
                    importCounts: &importCounts
                )
                return try handleImport(
                    index: Int(importIndex),
                    symbol: symbol,
                    state: &state,
                    memory: &memory,
                    heapCursor: &heapCursor,
                    allocations: &allocations,
                    openFiles: &openFiles,
                    runtimeObjects: &runtimeObjects,
                    runtimeEvents: &runtimeEvents,
                    readyContexts: &readyContexts,
                    sleepingContexts: &sleepingContexts,
                    mutexStates: &mutexStates,
                    mutexWaiters: &mutexWaiters,
                    currentInstruction: currentInstruction,
                    activeThreadHandle: &activeThreadHandle,
                    threadReturnValues: &threadReturnValues,
                    joinWaiters: &joinWaiters,
                    guestThreadCount: &guestThreadCount,
                    contextSwitchCount: &contextSwitchCount,
                    nextThreadStackTop: &nextThreadStackTop,
                    nextThreadTLSBlock: &nextThreadTLSBlock
                )
            }
            try push(instruction.nextAddress, state: &state, memory: &memory)
            state.rip = target
        case "ret", "retf":
            let target = try pop(state: &state, memory: memory)
            if target == Self.returnSentinel {
                let returnValue = state.readRegister("rax")
                threadReturnValues[activeThreadHandle] = returnValue
                if let waiters = joinWaiters.removeValue(forKey: activeThreadHandle) {
                    for waiter in waiters {
                        if waiter.resultAddress != 0 {
                            try writeInteger(
                                returnValue,
                                size: 8,
                                to: waiter.resultAddress,
                                memory: &memory
                            )
                        }
                        var waiterState = waiter.context.state
                        waiterState.writeRegister("rax", value: 0)
                        readyContexts.append(RunnableGuestContext(
                            state: waiterState,
                            threadHandle: waiter.context.threadHandle
                        ))
                    }
                }
                if !readyContexts.isEmpty {
                    let next = dequeueNextReadyContext(
                        from: &readyContexts,
                        joinWaiters: joinWaiters
                    )
                    state = next.state
                    activeThreadHandle = next.threadHandle
                    contextSwitchCount += 1
                    return nil
                }
                state.rip = target
                return .sentinelReturn
            }
            state.rip = target
            if let operand = operands.first {
                let adjustment = try read(operand, instruction: instruction, state: state, memory: memory)
                state.writeRegister("rsp", value: state.readRegister("rsp") &+ adjustment)
            }
        case "leave":
            state.writeRegister("rsp", value: state.readRegister("rbp"))
            state.writeRegister("rbp", value: try pop(state: &state, memory: memory))
        case "jmp":
            try requireOperands(operands, count: 1, instruction: instruction)
            let target = try read(operands[0], instruction: instruction, state: state, memory: memory)
            if let importIndex = try importStubIndex(at: target, memory: memory) {
                interceptedImports += 1
                let symbol = importSymbolsByIndex[Int(importIndex)]
                recordImport(
                    index: Int(importIndex),
                    symbol: symbol,
                    recentImports: &recentImports,
                    importCounts: &importCounts
                )
                if let reason = try handleImport(
                    index: Int(importIndex),
                    symbol: symbol,
                    state: &state,
                    memory: &memory,
                    heapCursor: &heapCursor,
                    allocations: &allocations,
                    openFiles: &openFiles,
                    runtimeObjects: &runtimeObjects,
                    runtimeEvents: &runtimeEvents,
                    readyContexts: &readyContexts,
                    sleepingContexts: &sleepingContexts,
                    mutexStates: &mutexStates,
                    mutexWaiters: &mutexWaiters,
                    currentInstruction: currentInstruction,
                    activeThreadHandle: &activeThreadHandle,
                    threadReturnValues: &threadReturnValues,
                    joinWaiters: &joinWaiters,
                    guestThreadCount: &guestThreadCount,
                    contextSwitchCount: &contextSwitchCount,
                    nextThreadStackTop: &nextThreadStackTop,
                    nextThreadTLSBlock: &nextThreadTLSBlock
                ) {
                    return reason
                }
                let returnAddress = try pop(state: &state, memory: memory)
                state.rip = returnAddress
                if returnAddress == Self.returnSentinel { return .sentinelReturn }
            } else {
                state.rip = target
            }
        case let mnemonic where mnemonic.hasPrefix("j"):
            try requireOperands(operands, count: 1, instruction: instruction)
            if try branchCondition(mnemonic, state: &state) {
                state.rip = try read(operands[0], instruction: instruction, state: state, memory: memory)
            }
        case let mnemonic where mnemonic.hasPrefix("cmov"):
            try requireOperands(operands, count: 2, instruction: instruction)
            if condition(String(mnemonic.dropFirst(4)), state: state) {
                let value = try read(operands[1], instruction: instruction, state: state, memory: memory)
                try write(value, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            }
        case let mnemonic where mnemonic.hasPrefix("set"):
            try requireOperands(operands, count: 1, instruction: instruction)
            let value: UInt64 = condition(String(mnemonic.dropFirst(3)), state: state) ? 1 : 0
            try write(value, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "add", "adc":
            try binaryArithmetic(
                instruction,
                carry: instruction.mnemonic == "adc" && state.flag(.carry) ? 1 : 0,
                subtract: false,
                state: &state,
                memory: &memory
            )
        case "sub", "sbb", "cmp":
            try binaryArithmetic(
                instruction,
                carry: instruction.mnemonic == "sbb" && state.flag(.carry) ? 1 : 0,
                subtract: true,
                writeResult: instruction.mnemonic != "cmp",
                state: &state,
                memory: &memory
            )
        case "xor", "or", "and", "test":
            try requireOperands(operands, count: 2, instruction: instruction)
            let lhs = try read(operands[0], instruction: instruction, state: state, memory: memory)
            let rhs = try read(operands[1], instruction: instruction, state: state, memory: memory)
            let result: UInt64
            switch instruction.mnemonic {
            case "xor": result = lhs ^ rhs
            case "or": result = lhs | rhs
            default: result = lhs & rhs
            }
            let masked = result & mask(forByteCount: operands[0].size)
            state.updateLogicFlags(result: masked, byteCount: operands[0].size)
            if instruction.mnemonic != "test" {
                try write(masked, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            }
        case "andn":
            // BMI1 ANDN writes the bitwise inverse of its first source ANDed
            // with its second source. Unlike legacy AND, both inputs are
            // independent of the destination register.
            try requireOperands(operands, count: 3, instruction: instruction)
            let invertedSource = try read(
                operands[1],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let source = try read(
                operands[2],
                instruction: instruction,
                state: state,
                memory: memory
            )
            let result = (~invertedSource & source) & mask(forByteCount: operands[0].size)
            state.updateLogicFlags(result: result, byteCount: operands[0].size)
            try write(
                result,
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "inc", "dec":
            try requireOperands(operands, count: 1, instruction: instruction)
            let oldCarry = state.flag(.carry)
            let lhs = try read(operands[0], instruction: instruction, state: state, memory: memory)
            let subtract = instruction.mnemonic == "dec"
            let result = subtract ? lhs &- 1 : lhs &+ 1
            if subtract {
                state.updateSubtractFlags(lhs: lhs, rhs: 1, result: result, byteCount: operands[0].size)
            } else {
                state.updateAddFlags(lhs: lhs, rhs: 1, result: result, byteCount: operands[0].size)
            }
            state.setFlag(.carry, oldCarry)
            try write(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "not", "neg":
            try requireOperands(operands, count: 1, instruction: instruction)
            let value = try read(operands[0], instruction: instruction, state: state, memory: memory)
            let result: UInt64
            if instruction.mnemonic == "not" {
                result = ~value
            } else {
                result = 0 &- value
                state.updateSubtractFlags(lhs: 0, rhs: value, result: result, byteCount: operands[0].size)
            }
            try write(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "imul":
            try signedMultiply(instruction, state: &state, memory: &memory)
        case "mul":
            try unsignedMultiply(instruction, state: &state, memory: memory)
        case "div":
            try unsignedDivide(instruction, state: &state, memory: memory)
        case "idiv":
            try signedDivide(instruction, state: &state, memory: memory)
        case "mulx":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try read(operands[2], instruction: instruction, state: state, memory: memory)
            let implicit = state.readRegister(operands[0].size == 4 ? "edx" : "rdx")
            let high: UInt64
            let low: UInt64
            if operands[0].size == 4 {
                let product = UInt64(UInt32(truncatingIfNeeded: implicit))
                    * UInt64(UInt32(truncatingIfNeeded: source))
                high = product >> 32
                low = product & 0xFFFF_FFFF
            } else {
                let product = implicit.multipliedFullWidth(by: source)
                high = product.high
                low = product.low
            }
            try write(low, to: operands[1], instruction: instruction, state: &state, memory: &memory)
            try write(high, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "shl", "sal", "shr", "sar":
            try shift(instruction, state: &state, memory: &memory)
        case "lzcnt", "tzcnt", "popcnt":
            try requireOperands(operands, count: 2, instruction: instruction)
            let source = try read(operands[1], instruction: instruction, state: state, memory: memory)
                & mask(forByteCount: operands[0].size)
            let result: UInt64
            switch mnemonic {
            case "lzcnt":
                result = operands[0].size == 4
                    ? UInt64(UInt32(truncatingIfNeeded: source).leadingZeroBitCount)
                    : UInt64(source.leadingZeroBitCount)
                state.setFlag(.carry, source == 0)
            case "tzcnt":
                result = operands[0].size == 4
                    ? UInt64(UInt32(truncatingIfNeeded: source).trailingZeroBitCount)
                    : UInt64(source.trailingZeroBitCount)
                state.setFlag(.carry, source == 0)
            default:
                result = UInt64(source.nonzeroBitCount)
                state.setFlag(.carry, false)
            }
            state.setFlag(.zero, result == 0)
            try write(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "bextr":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try read(operands[1], instruction: instruction, state: state, memory: memory)
            let control = try read(operands[2], instruction: instruction, state: state, memory: memory)
            let bitWidth = operands[0].size * 8
            let start = min(Int(control & 0xFF), bitWidth)
            let requestedLength = Int((control >> 8) & 0xFF)
            let length = min(requestedLength, bitWidth - start)
            let result: UInt64
            if length == 0 {
                result = 0
            } else {
                let fieldMask = length == 64 ? UInt64.max : (UInt64(1) << UInt64(length)) - 1
                result = (source >> UInt64(start)) & fieldMask
            }
            state.setFlag(.carry, false)
            state.setFlag(.overflow, false)
            state.setFlag(.zero, result == 0)
            try write(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "bzhi":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try read(operands[1], instruction: instruction, state: state, memory: memory)
            let index = Int(try read(operands[2], instruction: instruction, state: state, memory: memory) & 0xFF)
            let bitWidth = operands[0].size * 8
            let result: UInt64
            if index >= bitWidth {
                result = source & mask(forByteCount: operands[0].size)
                state.setFlag(.carry, true)
            } else if index == 0 {
                result = 0
                state.setFlag(.carry, false)
            } else {
                result = source & ((UInt64(1) << UInt64(index)) - 1)
                state.setFlag(.carry, false)
            }
            state.setFlag(.overflow, false)
            state.setFlag(.zero, result == 0)
            state.setFlag(
                .sign,
                result & (UInt64(1) << UInt64(bitWidth - 1)) != 0
            )
            try write(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "bt", "bts", "btr", "btc":
            try requireOperands(operands, count: 2, instruction: instruction)
            let base = try read(operands[0], instruction: instruction, state: state, memory: memory)
            let index = try read(operands[1], instruction: instruction, state: state, memory: memory)
            let bitWidth = UInt64(operands[0].size * 8)
            let bit = index % bitWidth
            let bitMask = UInt64(1) << bit
            state.setFlag(.carry, base & bitMask != 0)
            if mnemonic != "bt" {
                let result: UInt64
                switch mnemonic {
                case "bts": result = base | bitMask
                case "btr": result = base & ~bitMask
                default: result = base ^ bitMask
                }
                try write(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            }
        case "rorx":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try read(operands[1], instruction: instruction, state: state, memory: memory)
                & mask(forByteCount: operands[0].size)
            let countValue = try read(operands[2], instruction: instruction, state: state, memory: memory)
            let bitWidth = operands[0].size * 8
            let count = Int(countValue % UInt64(bitWidth))
            let result = count == 0
                ? source
                : (source >> UInt64(count)) | (source << UInt64(bitWidth - count))
            try write(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "shlx", "shrx", "sarx":
            try requireOperands(operands, count: 3, instruction: instruction)
            let source = try read(operands[1], instruction: instruction, state: state, memory: memory)
            let countValue = try read(operands[2], instruction: instruction, state: state, memory: memory)
            let bitCount = operands[0].size * 8
            let shiftMask: UInt64 = bitCount == 64 ? 0x3F : 0x1F
            let count = Int(countValue & shiftMask)
            let sourceMask = mask(forByteCount: operands[0].size)
            let maskedSource = source & sourceMask
            let result: UInt64
            switch mnemonic {
            case "shlx":
                result = maskedSource << UInt64(count)
            case "shrx":
                result = maskedSource >> UInt64(count)
            default:
                result = UInt64(bitPattern:
                    Int64(bitPattern: signExtend(maskedSource, fromByteCount: operands[0].size))
                        >> Int64(count)
                )
            }
            try write(
                result & sourceMask,
                to: operands[0],
                instruction: instruction,
                state: &state,
                memory: &memory
            )
        case "cmpxchg":
            try requireOperands(operands, count: 2, instruction: instruction)
            let accumulatorName: String
            switch operands[0].size {
            case 1: accumulatorName = "al"
            case 2: accumulatorName = "ax"
            case 4: accumulatorName = "eax"
            default: accumulatorName = "rax"
            }
            let accumulator = state.readRegister(accumulatorName)
            let destination = try read(operands[0], instruction: instruction, state: state, memory: memory)
            let result = accumulator &- destination
            state.updateSubtractFlags(
                lhs: accumulator,
                rhs: destination,
                result: result,
                byteCount: operands[0].size
            )
            if accumulator == destination {
                let source = try read(operands[1], instruction: instruction, state: state, memory: memory)
                try write(source, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            } else {
                state.writeRegister(accumulatorName, value: destination)
            }
        case "xadd":
            try requireOperands(operands, count: 2, instruction: instruction)
            let destination = try read(operands[0], instruction: instruction, state: state, memory: memory)
            let source = try read(operands[1], instruction: instruction, state: state, memory: memory)
            let result = destination &+ source
            state.updateAddFlags(
                lhs: destination,
                rhs: source,
                result: result,
                byteCount: operands[0].size
            )
            try write(result, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            try write(destination, to: operands[1], instruction: instruction, state: &state, memory: &memory)
        case "xchg":
            try requireOperands(operands, count: 2, instruction: instruction)
            let lhs = try read(operands[0], instruction: instruction, state: state, memory: memory)
            let rhs = try read(operands[1], instruction: instruction, state: state, memory: memory)
            try write(rhs, to: operands[0], instruction: instruction, state: &state, memory: &memory)
            try write(lhs, to: operands[1], instruction: instruction, state: &state, memory: &memory)
        case "movzx":
            try requireOperands(operands, count: 2, instruction: instruction)
            let value = try read(operands[1], instruction: instruction, state: state, memory: memory)
            try write(value, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "movsx", "movsxd":
            try requireOperands(operands, count: 2, instruction: instruction)
            let value = try read(operands[1], instruction: instruction, state: state, memory: memory)
            let extended = signExtend(value, fromByteCount: operands[1].size)
            try write(extended, to: operands[0], instruction: instruction, state: &state, memory: &memory)
        case "cbw":
            state.writeRegister("ax", value: signExtend(state.readRegister("al"), fromByteCount: 1))
        case "cwde":
            state.writeRegister("eax", value: signExtend(state.readRegister("ax"), fromByteCount: 2))
        case "cdqe":
            state.writeRegister("rax", value: signExtend(state.readRegister("eax"), fromByteCount: 4))
        case "cwd", "cdq", "cqo":
            let sourceName = instruction.mnemonic == "cwd" ? "ax" : instruction.mnemonic == "cdq" ? "eax" : "rax"
            let destinationName = instruction.mnemonic == "cwd" ? "dx" : instruction.mnemonic == "cdq" ? "edx" : "rdx"
            let width = instruction.mnemonic == "cwd" ? 2 : instruction.mnemonic == "cdq" ? 4 : 8
            let sign = state.readRegister(sourceName) & signBit(forByteCount: width)
            state.writeRegister(destinationName, value: sign == 0 ? 0 : mask(forByteCount: width))
        case "clc": state.setFlag(.carry, false)
        case "stc": state.setFlag(.carry, true)
        case "cld": state.setFlag(.direction, false)
        case "std": state.setFlag(.direction, true)
        case "cpuid":
            let leaf = UInt32(truncatingIfNeeded: state.readRegister("eax"))
            let subleaf = UInt32(truncatingIfNeeded: state.readRegister("ecx"))
            let output: (eax: UInt32, ebx: UInt32, ecx: UInt32, edx: UInt32)
            switch (leaf, subleaf) {
            case (0, _):
                output = (7, 0x756E_6547, 0x6C65_746E, 0x4965_6E69) // GenuineIntel
            case (1, _):
                output = (0x0003_06A9, 0, 0x7ED8_3203, 0x0780_0101)
            case (7, 0):
                output = (0, 0x0000_0328, 0, 0) // BMI1, AVX2, BMI2, ERMS
            case (0x8000_0000, _):
                output = (0x8000_0008, 0, 0, 0)
            case (0x8000_0001, _):
                output = (0, 0, 0x0000_0021, 0x2010_0000) // LAHF, ABM/LZCNT, NX, LM
            default:
                output = (0, 0, 0, 0)
            }
            state.writeRegister("eax", value: UInt64(output.eax))
            state.writeRegister("ebx", value: UInt64(output.ebx))
            state.writeRegister("ecx", value: UInt64(output.ecx))
            state.writeRegister("edx", value: UInt64(output.edx))
        case "syscall":
            return .systemCall(state.readRegister("rax"))
        case "hlt":
            return .halted("HLT")
        case "ud2", "int3":
            return .halted(instruction.mnemonic.uppercased())
        default:
            return .unsupportedInstruction(instruction.text)
        }
        return nil
    }

    private func binaryArithmetic(
        _ instruction: X86Instruction,
        carry: UInt64,
        subtract: Bool,
        writeResult: Bool = true,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws {
        try requireOperands(instruction.operands, count: 2, instruction: instruction)
        let destination = instruction.operands[0]
        let lhs = try read(destination, instruction: instruction, state: state, memory: memory)
        let source = try read(instruction.operands[1], instruction: instruction, state: state, memory: memory)
        let rhs = source &+ carry
        let result = subtract ? lhs &- rhs : lhs &+ rhs
        if subtract {
            state.updateSubtractFlags(lhs: lhs, rhs: rhs, result: result, byteCount: destination.size)
        } else {
            state.updateAddFlags(lhs: lhs, rhs: rhs, result: result, byteCount: destination.size)
        }
        if writeResult {
            try write(result, to: destination, instruction: instruction, state: &state, memory: &memory)
        }
    }

    private func signedMultiply(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws {
        let operands = instruction.operands
        guard operands.count == 2 || operands.count == 3 else {
            throw ARMInterpreterError.invalidOperand(instruction.text)
        }
        let destination = operands[0]
        let lhsOperand = operands.count == 2 ? operands[0] : operands[1]
        let rhsOperand = operands.count == 2 ? operands[1] : operands[2]
        let lhsRaw = try read(lhsOperand, instruction: instruction, state: state, memory: memory)
        let rhsRaw = try read(rhsOperand, instruction: instruction, state: state, memory: memory)
        let lhs = Int64(bitPattern: signExtend(lhsRaw, fromByteCount: destination.size))
        let rhs = Int64(bitPattern: signExtend(rhsRaw, fromByteCount: rhsOperand.size))
        let (product, hostOverflow) = lhs.multipliedReportingOverflow(by: rhs)
        let result = UInt64(bitPattern: product) & mask(forByteCount: destination.size)
        let represented = Int64(bitPattern: signExtend(result, fromByteCount: destination.size))
        let overflow = hostOverflow || represented != product
        state.setFlag(.carry, overflow)
        state.setFlag(.overflow, overflow)
        try write(result, to: destination, instruction: instruction, state: &state, memory: &memory)
    }

    private func shift(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws {
        try requireOperands(instruction.operands, count: 2, instruction: instruction)
        let destination = instruction.operands[0]
        let value = try read(destination, instruction: instruction, state: state, memory: memory)
        let countValue = try read(instruction.operands[1], instruction: instruction, state: state, memory: memory)
        let bitCount = destination.size * 8
        let shiftMask: UInt64 = bitCount == 64 ? 0x3F : 0x1F
        let count = Int(countValue & shiftMask)
        guard count > 0 else { return }
        let maskedValue = value & mask(forByteCount: destination.size)
        let result: UInt64
        switch instruction.mnemonic {
        case "shl", "sal":
            state.setFlag(.carry, ((maskedValue >> UInt64(bitCount - count)) & 1) != 0)
            result = maskedValue << UInt64(count)
        case "shr":
            state.setFlag(.carry, ((maskedValue >> UInt64(count - 1)) & 1) != 0)
            result = maskedValue >> UInt64(count)
        default:
            state.setFlag(.carry, ((maskedValue >> UInt64(count - 1)) & 1) != 0)
            result = UInt64(bitPattern: Int64(bitPattern: signExtend(maskedValue, fromByteCount: destination.size)) >> Int64(count))
        }
        let final = result & mask(forByteCount: destination.size)
        state.updateZeroSignParity(result: final, byteCount: destination.size)
        try write(final, to: destination, instruction: instruction, state: &state, memory: &memory)
    }

    private func unsignedDivide(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: SparseVirtualMemory
    ) throws {
        try requireOperands(instruction.operands, count: 1, instruction: instruction)
        let operand = instruction.operands[0]
        let divisor = try read(operand, instruction: instruction, state: state, memory: memory)
            & mask(forByteCount: operand.size)
        guard divisor != 0 else {
            throw ARMInterpreterError.invalidOperand("divide by zero: \(instruction.text)")
        }

        let quotient: UInt64
        let remainder: UInt64
        switch operand.size {
        case 1:
            let dividend = state.readRegister("ax")
            quotient = dividend / divisor
            remainder = dividend % divisor
            guard quotient <= 0xFF else {
                throw ARMInterpreterError.invalidOperand("division quotient overflow: \(instruction.text)")
            }
            state.writeRegister("al", value: quotient)
            state.writeRegister("ah", value: remainder)
        case 2:
            let dividend = (state.readRegister("dx") << 16) | state.readRegister("ax")
            quotient = dividend / divisor
            remainder = dividend % divisor
            guard quotient <= 0xFFFF else {
                throw ARMInterpreterError.invalidOperand("division quotient overflow: \(instruction.text)")
            }
            state.writeRegister("ax", value: quotient)
            state.writeRegister("dx", value: remainder)
        case 4:
            let dividend = (state.readRegister("edx") << 32) | state.readRegister("eax")
            quotient = dividend / divisor
            remainder = dividend % divisor
            guard quotient <= 0xFFFF_FFFF else {
                throw ARMInterpreterError.invalidOperand("division quotient overflow: \(instruction.text)")
            }
            state.writeRegister("eax", value: quotient)
            state.writeRegister("edx", value: remainder)
        case 8:
            let high = state.readRegister("rdx")
            guard high < divisor else {
                throw ARMInterpreterError.invalidOperand("division quotient overflow: \(instruction.text)")
            }
            let result = divisor.dividingFullWidth((high: high, low: state.readRegister("rax")))
            quotient = result.quotient
            remainder = result.remainder
            state.writeRegister("rax", value: quotient)
            state.writeRegister("rdx", value: remainder)
        default:
            throw ARMInterpreterError.unsupportedWidth(operand.size)
        }
    }

    private func signedDivide(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: SparseVirtualMemory
    ) throws {
        try requireOperands(instruction.operands, count: 1, instruction: instruction)
        let operand = instruction.operands[0]
        let rawDivisor = try read(operand, instruction: instruction, state: state, memory: memory)
        switch operand.size {
        case 1:
            let divisor = Int16(Int8(bitPattern: UInt8(truncatingIfNeeded: rawDivisor)))
            guard divisor != 0 else { throw ARMInterpreterError.invalidOperand("divide by zero: \(instruction.text)") }
            let dividend = Int16(bitPattern: UInt16(truncatingIfNeeded: state.readRegister("ax")))
            let quotient = dividend / divisor
            let remainder = dividend % divisor
            guard quotient >= Int16(Int8.min), quotient <= Int16(Int8.max) else {
                throw ARMInterpreterError.invalidOperand("division quotient overflow: \(instruction.text)")
            }
            state.writeRegister("al", value: UInt64(UInt8(bitPattern: Int8(quotient))))
            state.writeRegister("ah", value: UInt64(UInt8(bitPattern: Int8(remainder))))
        case 2:
            let divisor = Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: rawDivisor)))
            guard divisor != 0 else { throw ARMInterpreterError.invalidOperand("divide by zero: \(instruction.text)") }
            let bits = (UInt32(truncatingIfNeeded: state.readRegister("dx")) << 16)
                | UInt32(truncatingIfNeeded: state.readRegister("ax"))
            let dividend = Int32(bitPattern: bits)
            let quotient = dividend / divisor
            let remainder = dividend % divisor
            guard quotient >= Int32(Int16.min), quotient <= Int32(Int16.max) else {
                throw ARMInterpreterError.invalidOperand("division quotient overflow: \(instruction.text)")
            }
            state.writeRegister("ax", value: UInt64(UInt16(bitPattern: Int16(quotient))))
            state.writeRegister("dx", value: UInt64(UInt16(bitPattern: Int16(remainder))))
        case 4:
            let divisor = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: rawDivisor)))
            guard divisor != 0 else { throw ARMInterpreterError.invalidOperand("divide by zero: \(instruction.text)") }
            let bits = (state.readRegister("edx") << 32) | state.readRegister("eax")
            let dividend = Int64(bitPattern: bits)
            let quotient = dividend / divisor
            let remainder = dividend % divisor
            guard quotient >= Int64(Int32.min), quotient <= Int64(Int32.max) else {
                throw ARMInterpreterError.invalidOperand("division quotient overflow: \(instruction.text)")
            }
            state.writeRegister("eax", value: UInt64(UInt32(bitPattern: Int32(quotient))))
            state.writeRegister("edx", value: UInt64(UInt32(bitPattern: Int32(remainder))))
        case 8:
            let divisor = Int64(bitPattern: rawDivisor)
            guard divisor != 0 else { throw ARMInterpreterError.invalidOperand("divide by zero: \(instruction.text)") }
            let high = state.readRegister("rdx")
            let low = state.readRegister("rax")
            let signExtension = low & (UInt64(1) << 63) == 0 ? UInt64(0) : UInt64.max
            guard high == signExtension else {
                throw ARMInterpreterError.invalidOperand("128-bit signed dividend unsupported: \(instruction.text)")
            }
            let dividend = Int64(bitPattern: low)
            let division = dividend.dividedReportingOverflow(by: divisor)
            guard !division.overflow else {
                throw ARMInterpreterError.invalidOperand("division quotient overflow: \(instruction.text)")
            }
            let remainder = dividend.remainderReportingOverflow(dividingBy: divisor)
            state.writeRegister("rax", value: UInt64(bitPattern: division.partialValue))
            state.writeRegister("rdx", value: UInt64(bitPattern: remainder.partialValue))
        default:
            throw ARMInterpreterError.unsupportedWidth(operand.size)
        }
    }

    private func unsignedMultiply(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: SparseVirtualMemory
    ) throws {
        try requireOperands(instruction.operands, count: 1, instruction: instruction)
        let operand = instruction.operands[0]
        let source = try read(operand, instruction: instruction, state: state, memory: memory)
            & mask(forByteCount: operand.size)
        let high: UInt64
        switch operand.size {
        case 1:
            let product = state.readRegister("al") * source
            state.writeRegister("ax", value: product)
            high = product >> 8
        case 2:
            let product = state.readRegister("ax") * source
            state.writeRegister("ax", value: product)
            state.writeRegister("dx", value: product >> 16)
            high = product >> 16
        case 4:
            let product = state.readRegister("eax") * source
            state.writeRegister("eax", value: product)
            state.writeRegister("edx", value: product >> 32)
            high = product >> 32
        case 8:
            let product = state.readRegister("rax").multipliedFullWidth(by: source)
            state.writeRegister("rax", value: product.low)
            state.writeRegister("rdx", value: product.high)
            high = product.high
        default:
            throw ARMInterpreterError.unsupportedWidth(operand.size)
        }
        state.setFlag(.carry, high != 0)
        state.setFlag(.overflow, high != 0)
    }

    private func branchCondition(_ mnemonic: String, state: inout X86CPUState) throws -> Bool {
        switch mnemonic {
        case "jrcxz": return state.readRegister("rcx") == 0
        case "jecxz": return state.readRegister("ecx") == 0
        case "loop", "loope", "loopne":
            let value = state.readRegister("rcx") &- 1
            state.writeRegister("rcx", value: value)
            if mnemonic == "loope" { return value != 0 && state.flag(.zero) }
            if mnemonic == "loopne" { return value != 0 && !state.flag(.zero) }
            return value != 0
        default:
            return condition(String(mnemonic.dropFirst()), state: state)
        }
    }

    private func condition(_ suffix: String, state: X86CPUState) -> Bool {
        let carry = state.flag(.carry)
        let zero = state.flag(.zero)
        let sign = state.flag(.sign)
        let overflow = state.flag(.overflow)
        let parity = state.flag(.parity)
        switch suffix {
        case "e", "z": return zero
        case "ne", "nz": return !zero
        case "a", "nbe": return !carry && !zero
        case "ae", "nb", "nc": return !carry
        case "b", "c", "nae": return carry
        case "be", "na": return carry || zero
        case "g", "nle": return !zero && sign == overflow
        case "ge", "nl": return sign == overflow
        case "l", "nge": return sign != overflow
        case "le", "ng": return zero || sign != overflow
        case "o": return overflow
        case "no": return !overflow
        case "s": return sign
        case "ns": return !sign
        case "p", "pe": return parity
        case "np", "po": return !parity
        default: return false
        }
    }

    /// Supplies the compact shader binder's small DWORD table from the HLE
    /// heap. The guest's allocator is tied to AGC command-buffer ownership that
    /// is not present yet, but the table itself is ordinary zeroed CPU memory.
    private func executeShaderBindingTableAllocationIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory,
        heapCursor: inout UInt64,
        allocations: inout [UInt64: UInt64]
    ) throws -> Int? {
        guard instruction.text == "push rbp" else { return nil }
        let signature: [(UInt64, String)] = [
            (0x01, "mov rbp, rsp"),
            (0x04, "push r15"),
            (0x06, "push r14"),
            (0x08, "push r13"),
            (0x0A, "push r12"),
            (0x0C, "push rbx"),
            (0x23, "mov r14d, dword ptr [rdi + 0x38]"),
            (0x27, "test r14, r14")
        ]
        for (offset, expectedText) in signature {
            guard let candidate = try? decoder.decode(
                memory: memory,
                at: instruction.address + offset
            ), candidate.text == expectedText else { return nil }
        }

        let object = state.readRegister("rdi")
        guard object != 0 else { return nil }
        let entryCount = try readInteger(size: 4, from: object + 0x38, memory: memory)
        let oldTable = try readInteger(size: 8, from: object + 0x10, memory: memory)
        let byteCount = entryCount &* 4
        let table: UInt64
        if entryCount == 0 {
            table = 0
        } else {
            table = allocateGuestMemory(
                size: byteCount,
                alignment: 16,
                heapCursor: &heapCursor,
                allocations: &allocations
            )
            guard table != 0 else { return nil }
            try memory.write(Data(count: Int(byteCount)), at: table)
            if oldTable != 0 {
                let oldBytes = try memory.read(at: oldTable, length: Int(byteCount))
                try memory.write(oldBytes, at: table)
            }
        }
        try writeInteger(table, size: 8, to: object + 0x10, memory: &memory)
        state.writeRegister("rax", value: object)
        state.rip = try pop(state: &state, memory: memory)
        return Int(entryCount)
    }

    /// Collapses the title's JSON token-reader prologue, buffer bookkeeping,
    /// and character-class whitespace scan. The original function resumes at
    /// its token dispatch, or at its refill path when only trailing whitespace
    /// remains, with the exact callee-save stack frame it expects.
    private func executeJSONTokenEntryIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws -> Int? {
        guard instruction.text == "push rbp" else { return nil }
        let signature: [(UInt64, String)] = [
            (0x01, "mov rbp, rsp"),
            (0x04, "push r15"),
            (0x06, "push r14"),
            (0x08, "push rbx"),
            (0x09, "push rax"),
            (0x0A, "mov rdx, qword ptr [rdi + 0x70]"),
            (0x11, "lea r14, [rdi + 0x70]"),
            (0x15, "lea r15, [rip + 0x1d1274]"),
            (0x20, "mov qword ptr [rbx + 0x68], 0"),
            (0x28, "mov qword ptr [rbx + 0x60], rdx"),
            (0x4A, "movzx esi, byte ptr [rdx]"),
            (0x8A, "cmp sil, 0x5b")
        ]
        for (offset, expectedText) in signature {
            guard let candidate = try? decoder.decode(
                memory: memory,
                at: instruction.address + offset
            ), candidate.text == expectedText else { return nil }
        }

        let parser = state.readRegister("rdi")
        guard parser != 0 else { return nil }
        let current = try readInteger(size: 8, from: parser + 0x70, memory: memory)
        let end = try readInteger(size: 8, from: parser + 0x78, memory: memory)
        guard end >= current, end - current > 4, end - current <= UInt64(Int.max) else {
            return nil
        }
        let characterTableAddress = instruction.address + 0x1D1290
        let characterTable = try memory.read(at: characterTableAddress, length: 256)
        var tokenAddress = current
        var tokenByte: UInt8?
        var preferredChunkLength = 64
        while tokenAddress < end {
            let chunkLength = min(Int(end - tokenAddress), preferredChunkLength)
            let chunk = try memory.read(at: tokenAddress, length: chunkLength)
            if let index = chunk.firstIndex(where: {
                characterTable[Int($0)] & 0x20 == 0
            }) {
                tokenAddress += UInt64(index)
                tokenByte = chunk[index]
                break
            }
            tokenAddress += UInt64(chunk.count)
            preferredChunkLength = 4_096
        }
        let byteOffset = Int(tokenAddress - current)
        if tokenByte != nil, end - tokenAddress <= 4 {
            return nil
        }

        let oldRBP = state.readRegister("rbp")
        let oldR15 = state.readRegister("r15")
        let oldR14 = state.readRegister("r14")
        let oldRBX = state.readRegister("rbx")
        let oldRAX = state.readRegister("rax")
        try push(oldRBP, state: &state, memory: &memory)
        state.writeRegister("rbp", value: state.readRegister("rsp"))
        try push(oldR15, state: &state, memory: &memory)
        try push(oldR14, state: &state, memory: &memory)
        try push(oldRBX, state: &state, memory: &memory)
        try push(oldRAX, state: &state, memory: &memory)

        state.writeRegister("rbx", value: parser)
        state.writeRegister("r14", value: parser + 0x70)
        state.writeRegister("r15", value: characterTableAddress)
        state.writeRegister("rdx", value: tokenAddress)
        // The guest whitespace loop recomputes the remaining byte count from
        // the first non-whitespace byte before entering token dispatch.
        state.writeRegister("rax", value: end - tokenAddress)
        try writeInteger(0, size: 8, to: parser + 0x68, memory: &memory)
        try writeInteger(tokenAddress, size: 8, to: parser + 0x60, memory: &memory)
        try writeInteger(tokenAddress, size: 8, to: parser + 0x70, memory: &memory)

        if let tokenByte {
            state.writeRegister("rsi", value: UInt64(tokenByte))
            state.rip = instruction.address + 0x8A
        } else {
            state.rip = instruction.address + 0x77
        }
        return byteOffset
    }

    /// Completes the repeated decimal-digit loops in the JSON number reader,
    /// then resumes at the original delimiter/exponent classifier.
    private func executeJSONNumberRunIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws -> Int? {
        guard instruction.text == "inc rcx" else { return nil }
        let commonSignature: [(UInt64, String)] = [
            (0x03, "mov qword ptr [rbx + 0x70], rcx"),
            (0x07, "mov qword ptr [rbx + 0x68], rcx"),
            (0x0B, "mov rax, qword ptr [rbx + 0x78]"),
            (0x0F, "sub rax, rcx"),
            (0x12, "cmp rax, 2")
        ]
        for (offset, expectedText) in commonSignature {
            guard let candidate = try? decoder.decode(
                memory: memory,
                at: instruction.address + offset
            ), candidate.text == expectedText else { return nil }
        }
        let loopTarget = "0x\(String(instruction.address, radix: 16))"
        if let classifier = try? decoder.decode(memory: memory, at: instruction.address + 0x29),
           classifier.text == "movzx eax, byte ptr [rcx]",
           let loopBranch = try? decoder.decode(memory: memory, at: instruction.address + 0x38),
           loopBranch.text == "jb \(loopTarget)" {
            // Fractional digit loop.
        } else if let classifier = try? decoder.decode(
            memory: memory,
            at: instruction.address + 0x29
        ), classifier.text == "movzx edx, byte ptr [rcx]",
                  let loopBranch = try? decoder.decode(
                      memory: memory,
                      at: instruction.address + 0x42
                  ), loopBranch.text == "jae \(loopTarget)" {
            // Integer digit loop.
        } else {
            return nil
        }

        let parser = state.readRegister("rbx")
        let current = state.readRegister("rcx")
        guard parser != 0, current != UInt64.max else { return nil }
        let end = try readInteger(size: 8, from: parser + 0x78, memory: memory)
        let scanStart = current + 1
        guard end > scanStart, end - scanStart <= UInt64(Int.max) else { return nil }
        let scanLength = min(Int(end - scanStart), 1_024)
        let bytes = try memory.read(at: scanStart, length: scanLength)
        guard let nonDigit = bytes.firstIndex(where: { $0 < 0x30 || $0 > 0x39 }) else {
            return nil
        }
        let cursor = scanStart + UInt64(nonDigit)
        guard end - cursor > 2 else { return nil }
        state.writeRegister("rcx", value: cursor)
        try writeInteger(cursor, size: 8, to: parser + 0x70, memory: &memory)
        try writeInteger(cursor, size: 8, to: parser + 0x68, memory: &memory)
        state.rip = instruction.address + 0x29
        return nonDigit + 1
    }

    private func variantDiagnosticSummary(
        at address: UInt64,
        depth: Int,
        remainingNodes: inout Int,
        memory: SparseVirtualMemory
    ) throws -> String {
        guard remainingNodes > 0 else { return "..." }
        remainingNodes -= 1
        let type = try readInteger(size: 1, from: address, memory: memory)
        let payload = try readInteger(size: 8, from: address + 8, memory: memory)
        if type == 3, payload != 0,
           let byteCount = try? readInteger(size: 8, from: payload + 0x18, memory: memory),
           let capacity = try? readInteger(size: 8, from: payload + 0x20, memory: memory),
           byteCount <= 256 {
            let dataAddress = capacity >= 16
                ? try readInteger(size: 8, from: payload + 8, memory: memory)
                : payload + 8
            if let bytes = try? memory.read(at: dataAddress, length: Int(byteCount)) {
            let text = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: ",", with: "\\,")
            return "3:\(payload.hexadecimal):\"\(text)\""
            }
        }
        guard type == 2, depth > 0, payload != 0 else {
            return "\(type):\(payload.hexadecimal)"
        }
        let begin = try readInteger(size: 8, from: payload + 8, memory: memory)
        let end = try readInteger(size: 8, from: payload + 0x10, memory: memory)
        guard end >= begin, (end - begin).isMultiple(of: 16) else {
            return "2:invalid"
        }
        let totalCount = (end - begin) / 16
        let displayedCount = min(totalCount, 12)
        var children: [String] = []
        for index in 0..<displayedCount {
            children.append(try variantDiagnosticSummary(
                at: begin + index * 16,
                depth: depth - 1,
                remainingNodes: &remainingNodes,
                memory: memory
            ))
        }
        if displayedCount < totalCount { children.append("...") }
        return "2[\(totalCount)]{\(children.joined(separator: ","))}"
    }

    /// Completes the JSON token reader's common result write and callee-save
    /// epilogue in one interpreter turn.
    private func executeJSONTokenReturnIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws -> Bool {
        guard instruction.text == "mov dword ptr [rbx + 0x80], eax" else { return false }
        let signature: [(UInt64, String)] = [
            (0x06, "add rsp, 8"),
            (0x0A, "pop rbx"),
            (0x0B, "pop r14"),
            (0x0D, "pop r15"),
            (0x0F, "pop rbp"),
            (0x10, "ret")
        ]
        for (offset, expectedText) in signature {
            guard let candidate = try? decoder.decode(
                memory: memory,
                at: instruction.address + offset
            ), candidate.text == expectedText else { return false }
        }
        let parser = state.readRegister("rbx")
        let stack = state.readRegister("rsp")
        guard parser != 0, stack <= UInt64.max - 48 else { return false }

        // Read the whole epilogue frame before mutating guest memory or CPU
        // state so a malformed stack faults atomically.
        let restoredRBX = try readInteger(size: 8, from: stack + 8, memory: memory)
        let restoredR14 = try readInteger(size: 8, from: stack + 16, memory: memory)
        let restoredR15 = try readInteger(size: 8, from: stack + 24, memory: memory)
        let restoredRBP = try readInteger(size: 8, from: stack + 32, memory: memory)
        let returnRIP = try readInteger(size: 8, from: stack + 40, memory: memory)
        try writeInteger(
            state.readRegister("eax"),
            size: 4,
            to: parser + 0x80,
            memory: &memory
        )
        state.writeRegister("rbx", value: restoredRBX)
        state.writeRegister("r14", value: restoredR14)
        state.writeRegister("r15", value: restoredR15)
        state.writeRegister("rbp", value: restoredRBP)
        state.writeRegister("rsp", value: stack + 48)
        state.rip = returnRIP
        return true
    }

    /// Moves a contiguous run of the title's 16-byte variant records into a
    /// newly allocated vector and clears the source ownership fields. The
    /// original loop touches only the type byte and the payload qword, so the
    /// destination padding bytes are deliberately preserved.
    private func executeVariantMoveRunIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws -> Int? {
        guard instruction.text == "movzx edx, byte ptr [rbx + rcx]" else { return nil }
        let signature: [(UInt64, String)] = [
            (0x04, "lea rsi, [rbx + rcx + 0x10]"),
            (0x09, "mov byte ptr [r13 + rcx], dl"),
            (0x0E, "mov rdx, qword ptr [rbx + rcx + 8]"),
            (0x13, "mov qword ptr [r13 + rcx + 8], rdx"),
            (0x18, "mov byte ptr [rbx + rcx], 0"),
            (0x1C, "mov qword ptr [rbx + rcx + 8], 0"),
            (0x25, "add rcx, 0x10"),
            (0x29, "cmp rsi, rax"),
            (0x2E, "mov rbx, qword ptr [rdi + 8]")
        ]
        for (offset, expectedText) in signature {
            guard let candidate = try? decoder.decode(
                memory: memory,
                at: instruction.address + offset
            ), candidate.text == expectedText else { return nil }
        }
        let branchTarget = "0x\(String(instruction.address, radix: 16))"
        guard let branch = try? decoder.decode(memory: memory, at: instruction.address + 0x2C),
              branch.text == "jne \(branchTarget)" else { return nil }

        let sourceBase = state.readRegister("rbx")
        let destinationBase = state.readRegister("r13")
        let offset = state.readRegister("rcx")
        let sourceEnd = state.readRegister("rax")
        guard sourceBase <= UInt64.max - offset,
              destinationBase <= UInt64.max - offset else { return nil }
        let sourceStart = sourceBase + offset
        let destinationStart = destinationBase + offset
        guard sourceEnd > sourceStart else { return nil }
        let byteCount = sourceEnd - sourceStart
        guard byteCount.isMultiple(of: 16),
              byteCount <= 16_000_000,
              byteCount <= UInt64(Int.max),
              destinationStart <= UInt64.max - byteCount else { return nil }
        let destinationEnd = destinationStart + byteCount
        guard destinationEnd <= sourceStart || sourceEnd <= destinationStart else { return nil }

        var sourceBytes = try memory.read(at: sourceStart, length: Int(byteCount))
        var destinationBytes = try memory.read(at: destinationStart, length: Int(byteCount))
        var lastPayload: UInt64 = 0
        for recordOffset in stride(from: 0, to: Int(byteCount), by: 16) {
            destinationBytes[recordOffset] = sourceBytes[recordOffset]
            lastPayload = 0
            for payloadOffset in 8..<16 {
                let byte = sourceBytes[recordOffset + payloadOffset]
                destinationBytes[recordOffset + payloadOffset] = byte
                lastPayload |= UInt64(byte) << UInt64((payloadOffset - 8) * 8)
                sourceBytes[recordOffset + payloadOffset] = 0
            }
            sourceBytes[recordOffset] = 0
        }
        try memory.write(destinationBytes, at: destinationStart)
        try memory.write(sourceBytes, at: sourceStart)

        state.writeRegister("rdx", value: lastPayload)
        state.writeRegister("rsi", value: sourceEnd)
        state.writeRegister("rcx", value: offset + byteCount)
        state.rip = instruction.address + 0x2E
        return Int(byteCount / 16)
    }

    /// Collapses the title's recursive 16-byte variant destructor for scalar,
    /// string, and array-only subtrees. Type 1 is a tree/map whose erase helper
    /// has richer ownership semantics, so any subtree containing one falls back
    /// to the original guest routine before memory is changed.
    private func executeVariantDestructionIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws -> Int? {
        guard instruction.text == "push rbp" else { return nil }
        let signature: [(UInt64, String)] = [
            (0x01, "mov rbp, rsp"),
            (0x04, "push r15"),
            (0x11, "mov r12, qword ptr [rip + 0x39fbf0]"),
            (0x23, "mov al, byte ptr [rdi]"),
            (0x25, "cmp al, 3"),
            (0x2D, "cmp al, 2"),
            (0x31, "cmp al, 1"),
            (0x14A, "mov rax, qword ptr [r12]"),
            (0x162, "ret")
        ]
        for (offset, expectedText) in signature {
            guard let candidate = try? decoder.decode(
                memory: memory,
                at: instruction.address + offset
            ), candidate.text == expectedText else { return nil }
        }

        let root = state.readRegister("rdi")
        guard root != 0 else { return nil }
        guard let nodeCount = try destroyVariantTrees(
            roots: [root],
            destructorEntry: instruction.address,
            memory: &memory
        ) else { return nil }

        state.rip = try pop(state: &state, memory: memory)
        return nodeCount
    }

    /// Collapses an outer vector loop that calls the native variant destructor
    /// once per record. All records are preflighted before any ownership field
    /// is cleared, preserving the guest fallback for map/tree variants.
    private func executeVariantDestructionRunIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws -> Int? {
        guard instruction.text == "mov rdi, rbx" else { return nil }
        let signature: [(UInt64, String)] = [
            (0x03, "call 0x8000f46c0"),
            (0x08, "add rbx, 0x10"),
            (0x0C, "cmp r12, rbx"),
            (0x11, "mov rax, qword ptr [rbp - 0x38]")
        ]
        for (offset, expectedText) in signature {
            guard let candidate = try? decoder.decode(
                memory: memory,
                at: instruction.address + offset
            ), candidate.text == expectedText else { return nil }
        }
        let loopTarget = "0x\(String(instruction.address, radix: 16))"
        guard let branch = try? decoder.decode(memory: memory, at: instruction.address + 0x0F),
              branch.text == "jne \(loopTarget)" else { return nil }

        let begin = state.readRegister("rbx")
        let end = state.readRegister("r12")
        guard end > begin, (end - begin).isMultiple(of: 16) else { return nil }
        let rootCount = (end - begin) / 16
        guard rootCount <= 1_000_000, rootCount <= UInt64(Int.max) else { return nil }
        let roots = (0..<Int(rootCount)).map { begin + UInt64($0) * 16 }
        guard let nodeCount = try destroyVariantTrees(
            roots: roots,
            destructorEntry: 0x00000008000F46C0,
            memory: &memory
        ) else { return nil }

        state.writeRegister("rdi", value: end - 16)
        state.writeRegister("rbx", value: end)
        state.rip = instruction.address + 0x11
        return nodeCount
    }

    private func destroyVariantTrees(
        roots: [UInt64],
        destructorEntry: UInt64,
        memory: inout SparseVirtualMemory
    ) throws -> Int? {
        var pending = Array(roots.reversed())
        var destructionOrder: [UInt64] = []
        destructionOrder.reserveCapacity(max(roots.count, 64))
        while let object = pending.popLast() {
            guard destructionOrder.count < 1_000_000 else { return nil }
            let type = try readInteger(size: 1, from: object, memory: memory)
            if type == 1 { return nil }
            destructionOrder.append(object)
            guard type == 2 else {
                if type == 3 {
                    let string = try readInteger(size: 8, from: object + 8, memory: memory)
                    guard string != 0 else { return nil }
                    _ = try readInteger(size: 8, from: string + 0x20, memory: memory)
                }
                continue
            }

            let vector = try readInteger(size: 8, from: object + 8, memory: memory)
            guard vector != 0 else { return nil }
            let begin = try readInteger(size: 8, from: vector + 8, memory: memory)
            let end = try readInteger(size: 8, from: vector + 0x10, memory: memory)
            guard end >= begin, (end - begin).isMultiple(of: 16) else { return nil }
            let childCount = (end - begin) / 16
            guard childCount <= 1_000_000,
                  UInt64(destructionOrder.count) + childCount <= 1_000_000 else { return nil }
            if childCount > 0 {
                for index in (0..<childCount).reversed() {
                    pending.append(begin + index * 16)
                }
            }
        }

        let emptyStringState = try memory.read(
            at: destructorEntry + 0x1F63F0,
            length: 16
        )
        for object in destructionOrder.reversed() {
            let type = try readInteger(size: 1, from: object, memory: memory)
            switch type {
            case 2:
                let vector = try readInteger(size: 8, from: object + 8, memory: memory)
                let begin = try readInteger(size: 8, from: vector + 8, memory: memory)
                if begin != 0 {
                    try memory.write(Data(count: 24), at: vector + 8)
                }
            case 3:
                let string = try readInteger(size: 8, from: object + 8, memory: memory)
                try memory.write(emptyStringState, at: string + 0x18)
                try writeInteger(0, size: 1, to: string + 8, memory: &memory)
            default:
                break
            }
        }
        return destructionOrder.count
    }

    /// Consecutive NOPs are compiler alignment padding with no observable
    /// guest state. Decode through the run once and resume at the first real
    /// instruction instead of spending one interpreter turn per padding byte.
    private func executeNOPRunIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: SparseVirtualMemory
    ) -> Int? {
        guard instruction.mnemonic == "nop" else { return nil }
        var nextAddress = instruction.nextAddress
        var count = 1
        while count < 64,
              let candidate = try? decoder.decode(memory: memory, at: nextAddress),
              candidate.mnemonic == "nop" {
            nextAddress = candidate.nextAddress
            count += 1
        }
        guard count > 1 else { return nil }
        state.rip = nextAddress
        return count
    }

    /// Collapses a vectorized in-place float clamp loop used by the title's
    /// worker path. Bounds remain lane-specific and match SSE min/max NaN and
    /// equal-value source selection.
    private func executeFloatClampLoopIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws -> Int? {
        guard instruction.text == "vmovups ymm4, ymmword ptr [rbx + rax*4]" else { return nil }
        let signature: [(UInt64, String)] = [
            (0x05, "vminps ymm4, ymm4, ymm2"),
            (0x09, "vmaxps ymm4, ymm4, ymm3"),
            (0x0D, "vmovups ymmword ptr [rbx + rax*4], ymm4"),
            (0x12, "add rax, 8"),
            (0x16, "cmp rsi, rax"),
            (0x1B, "cmp rsi, rcx")
        ]
        for (offset, expectedText) in signature {
            guard let candidate = try? decoder.decode(
                memory: memory,
                at: instruction.address + offset
            ), candidate.text == expectedText else { return nil }
        }

        let buffer = state.readRegister("rbx")
        let start = state.readRegister("rax")
        let end = state.readRegister("rsi")
        guard buffer != 0, start < end, end - start <= UInt64(Int.max / 4) else { return nil }
        let count = Int(end - start)
        var samples = try memory.read(at: buffer + start * 4, length: count * 4)
        let upperBytes = try state.readVectorRegister("ymm2", byteCount: 32)
        let lowerBytes = try state.readVectorRegister("ymm3", byteCount: 32)
        for index in 0..<count {
            let lane = index & 7
            var sampleBits: UInt32 = 0
            var upperBits: UInt32 = 0
            var lowerBits: UInt32 = 0
            for byte in 0..<4 {
                sampleBits |= UInt32(samples[index * 4 + byte]) << UInt32(byte * 8)
                upperBits |= UInt32(upperBytes[lane * 4 + byte]) << UInt32(byte * 8)
                lowerBits |= UInt32(lowerBytes[lane * 4 + byte]) << UInt32(byte * 8)
            }
            let sample = Float(bitPattern: sampleBits)
            let upper = Float(bitPattern: upperBits)
            let lower = Float(bitPattern: lowerBits)
            let limited = sample.isNaN || upper.isNaN || sample == upper
                ? upper
                : min(sample, upper)
            let clamped = limited.isNaN || lower.isNaN || limited == lower
                ? lower
                : max(limited, lower)
            let outputBits = clamped.bitPattern
            for byte in 0..<4 {
                samples[index * 4 + byte] = UInt8(truncatingIfNeeded: outputBits >> UInt32(byte * 8))
            }
        }
        try memory.write(samples, at: buffer + start * 4)

        state.writeRegister("rax", value: end)
        state.updateSubtractFlags(lhs: end, rhs: end, result: 0, byteCount: 8)
        state.rip = instruction.address + 0x1B
        return count
    }

    /// Completes the byte-at-a-time Paeth reconstruction loop used by the
    /// bundled PNG decoder. The left predictor may overlap the output row, so
    /// the native pass preserves that dependency while processing a whole row.
    private func executePNGPaethScanlineLoopIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws -> Int? {
        guard instruction.text == "movzx edi, byte ptr [r9 + rsi]" else { return nil }

        let signature: [(Int64, String)] = [
            (-0x15, "add dil, byte ptr [r11 + rsi]"),
            (-0x11, "mov byte ptr [r13 + rsi], dil"),
            (-0x0C, "inc rsi"),
            (-0x09, "cmp r8, rsi"),
            (0x05, "movzx r15d, byte ptr [r14 + rsi]"),
            (0x0A, "movzx r12d, byte ptr [r10 + rsi]"),
            (0x0F, "lea edx, [r15 + rdi]"),
            (0x3B, "mov r12d, r15d"),
            (0xD8, "mov rax, qword ptr [rbp - 0x48]")
        ]
        for (signedOffset, expectedText) in signature {
            let address: UInt64
            if signedOffset < 0 {
                address = instruction.address - UInt64(-signedOffset)
            } else {
                address = instruction.address + UInt64(signedOffset)
            }
            let candidate = try decoder.decode(memory: memory, at: address)
            guard candidate.text == expectedText else { return nil }
        }

        let start = state.readRegister("rsi")
        let end = state.readRegister("r8")
        guard start < end, end <= UInt64(Int.max) else { return nil }
        let length = Int(end - start)
        let startIndex = Int(start)
        let endIndex = Int(end)
        let leftBase = state.readRegister("r9")
        let aboveBase = state.readRegister("r14")
        let upperLeftBase = state.readRegister("r10")
        let rawBase = state.readRegister("r11")
        let outputBase = state.readRegister("r13")
        guard leftBase != 0, aboveBase != 0, upperLeftBase != 0,
              rawBase != 0, outputBase != 0 else { return nil }

        let leftSnapshot = try memory.read(at: leftBase + start, length: length)
        let above = try memory.read(at: aboveBase + start, length: length)
        let upperLeft = try memory.read(at: upperLeftBase + start, length: length)
        let raw = try memory.read(at: rawBase + start, length: length)
        var output = try memory.read(at: outputBase, length: endIndex)
        for localIndex in 0..<length {
            let index = startIndex + localIndex
            let leftAddress = leftBase + UInt64(index)
            let left: UInt8
            if leftAddress >= outputBase, leftAddress < outputBase + end {
                left = output[Int(leftAddress - outputBase)]
            } else {
                left = leftSnapshot[localIndex]
            }
            let aboveValue = above[localIndex]
            let upperLeftValue = upperLeft[localIndex]

            let prediction = Int(left) + Int(aboveValue) - Int(upperLeftValue)
            let leftDistance = abs(prediction - Int(left))
            let aboveDistance = abs(prediction - Int(aboveValue))
            let upperLeftDistance = abs(prediction - Int(upperLeftValue))
            let alternative = aboveDistance > upperLeftDistance ? upperLeftValue : aboveValue
            let predictor = leftDistance > upperLeftDistance ? alternative : left
            output[index] = raw[localIndex] &+ predictor
        }
        try memory.write(output.subdata(in: startIndex..<endIndex), at: outputBase + start)

        state.writeRegister("rsi", value: end)
        state.updateSubtractFlags(lhs: end, rhs: end, result: 0, byteCount: 8)
        state.rip = instruction.address + 0xD8
        return length
    }

    /// Recognizes the scalar RGBA8 alpha-premultiplication loop used by the
    /// title's bundled image loader and completes it in one native ARM pass.
    /// The instruction signature and live image descriptor are both checked so
    /// this cannot accidentally replace an unrelated `mov ecx, esi` sequence.
    private func executeRGBA8PremultiplicationLoopIfPresent(
        _ instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws -> Int? {
        guard instruction.text == "mov ecx, esi" else { return nil }

        let signature: [(UInt64, String)] = [
            (0x02, "lea eax, [rsi + 3]"),
            (0x05, "movzx edi, byte ptr [r13 + rcx]"),
            (0x0B, "movzx ebx, byte ptr [r13 + rax]"),
            (0x5E, "movsxd rax, dword ptr [r10 + 8]"),
            (0x62, "movsxd rcx, dword ptr [r10 + 0xc]"),
            (0x6A, "cmp r9, rcx"),
            (0x76, "add esi, 4"),
            (0x7B, "mov edx, dword ptr [r10 + 0x20]")
        ]
        for (offset, expectedText) in signature {
            let candidate = try decoder.decode(memory: memory, at: instruction.address + offset)
            guard candidate.text == expectedText else { return nil }
        }

        let descriptor = state.readRegister("r10")
        guard descriptor != 0 else { return nil }
        let widthBits = UInt32(truncatingIfNeeded: try readInteger(
            size: 4,
            from: descriptor + 8,
            memory: memory
        ))
        let heightBits = UInt32(truncatingIfNeeded: try readInteger(
            size: 4,
            from: descriptor + 0x0C,
            memory: memory
        ))
        let width = Int64(Int32(bitPattern: widthBits))
        let height = Int64(Int32(bitPattern: heightBits))
        guard width > 0, height > 0 else { return nil }
        let (signedPixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, signedPixelCount > 0 else { return nil }
        let pixelCount = UInt64(signedPixelCount)
        let oneBasedPixelIndex = state.readRegister("r9")
        let byteOffset = UInt64(UInt32(truncatingIfNeeded: state.readRegister("rsi")))
        let dataAddress = try readInteger(size: 8, from: descriptor + 0x18, memory: memory)
        guard oneBasedPixelIndex > 0,
              oneBasedPixelIndex <= pixelCount,
              byteOffset == (oneBasedPixelIndex - 1) &* 4,
              dataAddress != 0,
              state.readRegister("r13") == dataAddress
        else { return nil }

        let remainingPixels = pixelCount - oneBasedPixelIndex + 1
        let (remainingByteCount, byteCountOverflow) = remainingPixels.multipliedReportingOverflow(by: 4)
        guard !byteCountOverflow, remainingByteCount <= UInt64(Int.max) else { return nil }
        if remainingByteCount > 0 {
            var pixels = try memory.read(
                at: dataAddress + byteOffset,
                length: Int(remainingByteCount)
            )
            pixels.withUnsafeMutableBytes { rawBuffer in
                guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                for offset in stride(from: 0, to: rawBuffer.count, by: 4) {
                    let alpha = UInt32(bytes[offset + 3])
                    for component in 0..<3 {
                        let product = UInt32(bytes[offset + component]) * alpha
                        bytes[offset + component] = UInt8((product * 0x8081) >> 23)
                    }
                }
            }
            try memory.write(pixels, at: dataAddress + byteOffset)
        }

        state.writeRegister("r9", value: pixelCount)
        state.writeRegister("esi", value: UInt64(truncatingIfNeeded: (pixelCount - 1) &* 4))
        state.writeRegister("r13", value: dataAddress)
        state.writeRegister("rax", value: UInt64(width))
        state.writeRegister("rcx", value: pixelCount)
        state.updateSubtractFlags(lhs: pixelCount, rhs: pixelCount, result: 0, byteCount: 8)
        state.rip = instruction.address + 0x7B
        return Int(remainingPixels)
    }

    private func read(
        _ operand: X86Operand,
        instruction: X86Instruction,
        state: X86CPUState,
        memory: SparseVirtualMemory
    ) throws -> UInt64 {
        let value: UInt64
        switch operand.value {
        case let .register(name):
            value = try state.checkedReadRegister(name)
        case let .immediate(immediate):
            value = immediate
        case let .memory(memoryOperand):
            let address = try effectiveAddress(
                memoryOperand,
                nextInstruction: instruction.nextAddress,
                state: state
            )
            value = try readInteger(size: operand.size, from: address, memory: memory)
        }
        return value & mask(forByteCount: operand.size)
    }

    private func readBytes(
        _ operand: X86Operand,
        instruction: X86Instruction,
        state: X86CPUState,
        memory: SparseVirtualMemory
    ) throws -> Data {
        switch operand.value {
        case let .register(name) where X86CPUState.isVectorRegister(name):
            return try state.readVectorRegister(name, byteCount: operand.size)
        case .register, .immediate:
            let value = try read(operand, instruction: instruction, state: state, memory: memory)
            let count = min(operand.size, 8)
            var data = Data(count: count)
            for index in 0..<count {
                data[index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
            }
            return data
        case let .memory(memoryOperand):
            let address = try effectiveAddress(
                memoryOperand,
                nextInstruction: instruction.nextAddress,
                state: state
            )
            return try memory.read(at: address, length: operand.size)
        }
    }

    private func writeBytes(
        _ bytes: Data,
        to operand: X86Operand,
        instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws {
        switch operand.value {
        case let .register(name) where X86CPUState.isVectorRegister(name):
            try state.writeVectorRegister(name, bytes: bytes, byteCount: operand.size)
        case .register:
            guard operand.size <= 8 else { throw ARMInterpreterError.unsupportedWidth(operand.size) }
            var value: UInt64 = 0
            for index in 0..<min(bytes.count, operand.size) {
                value |= UInt64(bytes[index]) << UInt64(index * 8)
            }
            try write(value, to: operand, instruction: instruction, state: &state, memory: &memory)
        case let .memory(memoryOperand):
            let address = try effectiveAddress(
                memoryOperand,
                nextInstruction: instruction.nextAddress,
                state: state
            )
            var output = Data(repeating: 0, count: operand.size)
            output.replaceSubrange(0..<min(bytes.count, output.count), with: bytes.prefix(output.count))
            try memory.write(output, at: address)
        case .immediate:
            throw ARMInterpreterError.invalidOperand("cannot write an immediate")
        }
    }

    private func write(
        _ value: UInt64,
        to operand: X86Operand,
        instruction: X86Instruction,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory
    ) throws {
        let masked = value & mask(forByteCount: operand.size)
        switch operand.value {
        case let .register(name):
            try state.checkedWriteRegister(name, value: masked)
        case let .memory(memoryOperand):
            let address = try effectiveAddress(
                memoryOperand,
                nextInstruction: instruction.nextAddress,
                state: state
            )
            try writeInteger(masked, size: operand.size, to: address, memory: &memory)
        case .immediate:
            throw ARMInterpreterError.invalidOperand("cannot write an immediate")
        }
    }

    private func effectiveAddress(
        _ operand: X86MemoryOperand,
        nextInstruction: UInt64,
        state: X86CPUState
    ) throws -> UInt64 {
        var address = UInt64(bitPattern: operand.displacement)
        if let base = operand.base {
            address &+= base == "rip" ? nextInstruction : try state.checkedReadRegister(base)
        }
        if let index = operand.index {
            let indexValue = try state.checkedReadRegister(index)
            address &+= indexValue &* UInt64(bitPattern: Int64(operand.scale))
        }
        if operand.segment == "fs" { address &+= state.fsBase }
        if operand.segment == "gs" { address &+= state.gsBase }
        return address
    }

    private func readInteger(size: Int, from address: UInt64, memory: SparseVirtualMemory) throws -> UInt64 {
        guard (1...8).contains(size) else { throw ARMInterpreterError.unsupportedWidth(size) }
        let data = try memory.read(at: address, length: size)
        var value: UInt64 = 0
        for index in 0..<size {
            value |= UInt64(data[index]) << UInt64(index * 8)
        }
        return value
    }

    private func importStubIndex(at address: UInt64, memory: SparseVirtualMemory) throws -> UInt32? {
        let bytes: Data
        do {
            bytes = try memory.fetch(at: address, length: 15)
        } catch {
            return nil
        }
        guard bytes.count >= 15,
              bytes[0] == 0xFF, bytes[1] == 0x25,
              bytes[6] == 0x68, bytes[11] == 0xE9 else {
            return nil
        }
        var index: UInt32 = 0
        for offset in 0..<4 {
            index |= UInt32(bytes[7 + offset]) << UInt32(offset * 8)
        }
        return index
    }

    private func recordImport(
        index: Int,
        symbol: String?,
        recentImports: inout [String],
        importCounts: inout [String: Int]
    ) {
        let name = symbol ?? "<unknown:#\(index)>"
        recentImports.append("#\(index) \(name)")
        if recentImports.count > 512 { recentImports.removeFirst() }
        importCounts[name, default: 0] += 1
    }

    private func recordRuntimeEvent(_ event: String, events: inout [String]) {
        events.append(event)
        if events.count > 256 { events.removeFirst() }
        runtimeEventHandler?(event)
    }

    private func handleImport(
        index: Int,
        symbol: String?,
        state: inout X86CPUState,
        memory: inout SparseVirtualMemory,
        heapCursor: inout UInt64,
        allocations: inout [UInt64: UInt64],
        openFiles: inout [UInt64: GuestOpenFile],
        runtimeObjects: inout [String: UInt64],
        runtimeEvents: inout [String],
        readyContexts: inout [RunnableGuestContext],
        sleepingContexts: inout [SleepingGuestContext],
        mutexStates: inout [UInt64: GuestMutexState],
        mutexWaiters: inout [UInt64: [GuestMutexWaiter]],
        currentInstruction: Int,
        activeThreadHandle: inout UInt64,
        threadReturnValues: inout [UInt64: UInt64],
        joinWaiters: inout [UInt64: [GuestJoinWaiter]],
        guestThreadCount: inout Int,
        contextSwitchCount: inout Int,
        nextThreadStackTop: inout UInt64,
        nextThreadTLSBlock: inout UInt64
    ) throws -> ARMExecutionStopReason? {
        guard let symbol else {
            state.writeRegister("rax", value: 0)
            return nil
        }

        switch symbol {
        case "cfAXurvfl5o":
            // __cxa_allocate_exception. The guest constructs the exception
            // object in this storage before passing it to __cxa_throw.
            state.writeRegister("rax", value: allocateGuestMemory(
                size: state.readRegister("rdi"),
                alignment: 16,
                heapCursor: &heapCursor,
                allocations: &allocations
            ))
        case "vkuuLfhnSZI":
            // __cxa_throw. Preserve the diagnostic carried by the title's
            // std::exception-compatible object instead of falling through to
            // the compiler's following UD2 with no actionable context.
            let object = state.readRegister("rdi")
            var message = "unknown guest C++ exception"
            if object != 0,
               let length = try? readInteger(size: 8, from: object + 0x20, memory: memory),
               let capacity = try? readInteger(size: 8, from: object + 0x28, memory: memory),
               length <= 16 * 1_024 {
                let textAddress: UInt64?
                if capacity >= 16 {
                    textAddress = try? readInteger(size: 8, from: object + 0x10, memory: memory)
                } else {
                    textAddress = object + 0x10
                }
                if let textAddress,
                   let bytes = try? memory.read(at: textAddress, length: Int(length)) {
                    message = String(decoding: bytes, as: UTF8.self)
                }
            }
            recordRuntimeEvent("guest C++ exception: \(message)", events: &runtimeEvents)
            return .halted("guest C++ exception: \(message)")
        case "gQX+4GDQjpM", "fJnpuVVBbKk", "hdm0YfMa7TQ", "ryUxD-60bKM":
            state.writeRegister("rax", value: allocateGuestMemory(
                size: state.readRegister("rdi"),
                alignment: 16,
                heapCursor: &heapCursor,
                allocations: &allocations
            ))
        case "2Btkg8k24Zg", "Ujf3KzMvRmI":
            state.writeRegister("rax", value: allocateGuestMemory(
                size: state.readRegister("rsi"),
                alignment: state.readRegister("rdi"),
                heapCursor: &heapCursor,
                allocations: &allocations
            ))
        case "OJjm-QOIHlI":
            state.writeRegister("rax", value: allocateGuestMemory(
                size: state.readRegister("rsi"),
                alignment: 16,
                heapCursor: &heapCursor,
                allocations: &allocations
            ))
        case "iF1iQHzxBJU":
            state.writeRegister("rax", value: allocateGuestMemory(
                size: state.readRegister("rdx"),
                alignment: state.readRegister("rsi"),
                heapCursor: &heapCursor,
                allocations: &allocations
            ))
        case "LYo3GhIlB38":
            state.writeRegister("rax", value: allocateGuestMemory(
                size: state.readRegister("rsi") &* state.readRegister("rdx"),
                alignment: 16,
                heapCursor: &heapCursor,
                allocations: &allocations
            ))
        case "2X5agFjKxMc":
            state.writeRegister("rax", value: allocateGuestMemory(
                size: state.readRegister("rdi") &* state.readRegister("rsi"),
                alignment: 16,
                heapCursor: &heapCursor,
                allocations: &allocations
            ))
        case "Y7aJ1uydPMo", "gigoVHZvVPE", "OGybVuPAhAY":
            let oldPointer = symbol == "gigoVHZvVPE" ? state.readRegister("rsi") : state.readRegister("rdi")
            let newSize = symbol == "gigoVHZvVPE" ? state.readRegister("rdx") : state.readRegister("rsi")
            let newPointer = allocateGuestMemory(
                size: newSize,
                alignment: 16,
                heapCursor: &heapCursor,
                allocations: &allocations
            )
            if oldPointer != 0, let oldSize = allocations[oldPointer] {
                let copySize = min(oldSize, newSize)
                if copySize <= UInt64(Int.max) {
                    let bytes = try memory.read(at: oldPointer, length: Int(copySize))
                    try memory.write(bytes, at: newPointer)
                }
            }
            state.writeRegister("rax", value: newPointer)
        case "cVSk9y8URbc":
            let pointer = allocateGuestMemory(
                size: state.readRegister("rdx"),
                alignment: state.readRegister("rsi"),
                heapCursor: &heapCursor,
                allocations: &allocations
            )
            try writeInteger(pointer, size: 8, to: state.readRegister("rdi"), memory: &memory)
            state.writeRegister("rax", value: 0)
        case "pO96TwzOm5E":
            // sceKernelGetDirectMemorySize
            state.writeRegister("rax", value: 16 * 1_024 * 1_024 * 1_024)
        case "rTXw65xmLIA":
            // sceKernelAllocateDirectMemory. Direct-memory offsets are opaque to
            // the guest until they are passed to sceKernelMapDirectMemory.
            let outputAddress = state.readRegister("r9")
            if outputAddress != 0 {
                try writeInteger(0, size: 8, to: outputAddress, memory: &memory)
                state.writeRegister("rax", value: 0)
            } else {
                state.writeRegister("rax", value: UInt64.max)
            }
        case "L-Q3LEjIbgA", "NcaWUxfMNIQ":
            // sceKernelMapDirectMemory / sceKernelMapNamedDirectMemory
            let outputAddress = state.readRegister("rdi")
            let length = state.readRegister("rsi")
            if outputAddress != 0, length > 0 {
                let requestedAlignment = state.readRegister("r9")
                let pointer = allocateGuestMemory(
                    size: length,
                    alignment: max(requestedAlignment, SparseVirtualMemory.pageSize),
                    heapCursor: &heapCursor,
                    allocations: &allocations
                )
                try writeInteger(pointer, size: 8, to: outputAddress, memory: &memory)
                state.writeRegister("rax", value: 0)
            } else {
                state.writeRegister("rax", value: UInt64.max)
            }
        case "6UgtwV+0zb4", "OxhIB8LB-PQ", "Jmi+9w9u0E4":
            // scePthreadCreate and POSIX aliases. Execute the guest thread
            // cooperatively on this interpreter, then resume the creator when
            // the thread entry returns or calls pthread_exit.
            let outputAddress = state.readRegister("rdi")
            let entryAddress = state.readRegister("rdx")
            let argument = state.readRegister("rcx")
            guard outputAddress != 0, entryAddress != 0,
                  nextThreadStackTop > Self.stackBase + 0x1000,
                  nextThreadTLSBlock + Self.threadLocalStorageBlockSize
                    <= Self.threadLocalStorageBase + Self.threadLocalStorageSize
            else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }

            let handle = allocateGuestMemory(
                size: 0x1000,
                alignment: 16,
                heapCursor: &heapCursor,
                allocations: &allocations
            )
            try writeInteger(handle, size: 8, to: outputAddress, memory: &memory)
            state.writeRegister("rax", value: 0)
            readyContexts.append(RunnableGuestContext(
                state: state,
                threadHandle: activeThreadHandle
            ))

            var threadState = X86CPUState(rip: entryAddress)
            threadState.writeRegister("rdi", value: argument)
            threadState.writeRegister("rsp", value: nextThreadStackTop)
            threadState.fsBase = nextThreadTLSBlock + Self.threadControlBlockOffset
            threadState.gsBase = threadState.fsBase
            try writeInteger(threadState.fsBase, size: 8, to: threadState.fsBase, memory: &memory)
            try push(Self.returnSentinel, state: &threadState, memory: &memory)

            nextThreadStackTop &-= Self.guestThreadStackSize
            nextThreadTLSBlock &+= Self.threadLocalStorageBlockSize
            guestThreadCount += 1
            contextSwitchCount += 1
            activeThreadHandle = handle
            state = threadState
        case "onNY9Byn-W8":
            let handle = state.readRegister("rdi")
            let outputAddress = state.readRegister("rsi")
            if let returnValue = threadReturnValues[handle] {
                if outputAddress != 0 {
                    try writeInteger(returnValue, size: 8, to: outputAddress, memory: &memory)
                }
                state.writeRegister("rax", value: 0)
            } else if !readyContexts.isEmpty {
                joinWaiters[handle, default: []].append(GuestJoinWaiter(
                    context: RunnableGuestContext(
                        state: state,
                        threadHandle: activeThreadHandle
                    ),
                    resultAddress: outputAddress
                ))
                let next = dequeueNextReadyContext(
                    from: &readyContexts,
                    joinWaiters: joinWaiters
                )
                state = next.state
                activeThreadHandle = next.threadHandle
                contextSwitchCount += 1
            } else {
                // An invalid or self join cannot make progress in this compact
                // scheduler. Report success instead of deadlocking the process.
                state.writeRegister("rax", value: 0)
            }
        case "3kg7rT0NQIs", "FJrT5LuUBAU":
            let returnValue = state.readRegister("rdi")
            threadReturnValues[activeThreadHandle] = returnValue
            if let waiters = joinWaiters.removeValue(forKey: activeThreadHandle) {
                for waiter in waiters {
                    if waiter.resultAddress != 0 {
                        try writeInteger(
                            returnValue,
                            size: 8,
                            to: waiter.resultAddress,
                            memory: &memory
                        )
                    }
                    var waiterState = waiter.context.state
                    waiterState.writeRegister("rax", value: 0)
                    readyContexts.append(RunnableGuestContext(
                        state: waiterState,
                        threadHandle: waiter.context.threadHandle
                    ))
                }
            }
            if !readyContexts.isEmpty {
                let next = dequeueNextReadyContext(
                    from: &readyContexts,
                    joinWaiters: joinWaiters
                )
                state = next.state
                activeThreadHandle = next.threadHandle
                contextSwitchCount += 1
            } else {
                state.writeRegister("rax", value: returnValue)
                return .halted("guest pthread_exit(\(returnValue))")
            }
        case "JfEPXVxhFqA":
            // sceAudioOutInit
            state.writeRegister("rax", value: 0)
        case "ekNvsT22rsY":
            // sceAudioOutOpen(userId, type, index, frames, frequency, format)
            if let port = audioPorts.open(
                bufferLength: state.readRegister("rcx"),
                frequency: state.readRegister("r8"),
                format: state.readRegister("r9")
            ) {
                state.writeRegister("rax", value: port.handle)
            } else {
                state.writeRegister("rax", value: UInt64.max)
            }
        case "s1--uE9mBFw":
            // sceAudioOutClose
            state.writeRegister(
                "rax",
                value: audioPorts.close(handle: state.readRegister("rdi")) ? 0 : UInt64.max
            )
        case "b+uAV89IlxE":
            // sceAudioOutSetVolume. Host gain stays at unity; the guest PCM is
            // already mixed and scaled for the selected output port.
            state.writeRegister("rax", value: 0)
        case "QOQtbeDqsT4":
            // sceAudioOutOutput. Copy the guest buffer before yielding so the
            // title can safely reuse it while AVAudioEngine owns the host copy.
            let handle = state.readRegister("rdi")
            let sourceAddress = state.readRegister("rsi")
            guard let port = audioPorts.port(for: handle),
                  port.byteCount > 0
            else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }
            guard sourceAddress != 0 else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            let pcm = try memory.read(at: sourceAddress, length: port.byteCount)
            audioBufferHandler?(GuestAudioBuffer(
                sampleRate: port.sampleRate,
                channelCount: port.channelCount,
                frameCount: port.frameCount,
                isFloat: port.isFloat,
                data: pcm
            ))
            state.writeRegister("rax", value: 0)
            if !readyContexts.isEmpty {
                sleepingContexts.append(SleepingGuestContext(
                    context: RunnableGuestContext(
                        state: state,
                        threadHandle: activeThreadHandle
                    ),
                    wakeInstruction: currentInstruction + 53_333,
                    mutexToReacquire: nil,
                    mutexDepth: 0
                ))
                let next = dequeueNextReadyContext(
                    from: &readyContexts,
                    joinWaiters: joinWaiters
                )
                state = next.state
                activeThreadHandle = next.threadHandle
                contextSwitchCount += 1
            }
        case "hv1luiJrqQM":
            // scePadInit
            state.writeRegister("rax", value: 0)
        case "xk0AcarP3V4":
            // scePadOpen. VibeStation5 exposes a single merged virtual pad.
            state.writeRegister("rax", value: 1)
        case "clVvL4ZDntw", "W2G-yoyMF5U", "yFVnOdGxvZY",
             "RR4novUEENY", "DscD1i9HX1w":
            // Motion, vibration, and light-bar controls are accepted. Input
            // remains available even when a host device has no matching output.
            state.writeRegister("rax", value: 0)
        case "gjP9-KQzoUk":
            // scePadGetControllerInformation
            let informationAddress = state.readRegister("rsi")
            if informationAddress != 0 {
                try memory.write(GuestInputState.controllerInformation(), at: informationAddress)
                state.writeRegister("rax", value: 0)
            } else {
                state.writeRegister("rax", value: UInt64.max)
            }
        case "YndgXqQVV7c", "q1cHNfGycLI":
            // scePadReadState / scePadRead
            let dataAddress = state.readRegister("rsi")
            let requestedCount = symbol == "q1cHNfGycLI" ? state.readRegister("rdx") : 1
            guard dataAddress != 0, requestedCount > 0 else {
                state.writeRegister("rax", value: symbol == "q1cHNfGycLI" ? 0 : UInt64.max)
                return nil
            }
            let timestamp = DispatchTime.now().uptimeNanoseconds / 1_000
            let padData = (inputStateProvider?() ?? .neutral).guestPadData(
                timestampMicroseconds: timestamp
            )
            try memory.write(padData, at: dataAddress)
            state.writeRegister("rax", value: symbol == "q1cHNfGycLI" ? 1 : 0)
        case "BmMjYxmew1w", "WKAXJ4XBPQ4", "Zxa0VhQVTsk", "1jfXLRVzisc",
             "fzyMKs9kim0":
            // Timed condition waits, semaphore waits, and usleep are natural
            // cooperative scheduling points. Park the waiter for bounded guest
            // time instead of immediately requeueing an idle worker. A condition
            // wait atomically releases its mutex and reacquires it before return.
            state.writeRegister("rax", value: 0)
            if !readyContexts.isEmpty {
                let isConditionWait = symbol == "BmMjYxmew1w" || symbol == "WKAXJ4XBPQ4"
                let conditionMutex = isConditionWait ? state.readRegister("rsi") : 0
                var mutexDepth = 0
                if conditionMutex != 0 {
                    if let heldMutex = mutexStates[conditionMutex],
                       heldMutex.owner == activeThreadHandle {
                        mutexDepth = heldMutex.depth
                        if var waiters = mutexWaiters[conditionMutex], !waiters.isEmpty {
                            let waiter = waiters.removeFirst()
                            if waiters.isEmpty {
                                mutexWaiters.removeValue(forKey: conditionMutex)
                            } else {
                                mutexWaiters[conditionMutex] = waiters
                            }
                            mutexStates[conditionMutex] = GuestMutexState(
                                owner: waiter.context.threadHandle,
                                depth: waiter.depth
                            )
                            var waiterState = waiter.context.state
                            waiterState.writeRegister("rax", value: 0)
                            readyContexts.append(RunnableGuestContext(
                                state: waiterState,
                                threadHandle: waiter.context.threadHandle
                            ))
                        } else {
                            mutexStates.removeValue(forKey: conditionMutex)
                        }
                    } else if mutexStates[conditionMutex] == nil {
                        // Some titles use statically initialized mutex storage.
                        // Preserve the required reacquisition even if the first
                        // observed operation is the condition wait itself.
                        mutexDepth = 1
                    }
                }
                let requestedDelay: UInt64
                if symbol == "1jfXLRVzisc" {
                    requestedDelay = state.readRegister("rdi") &* 10
                } else if symbol == "BmMjYxmew1w" {
                    requestedDelay = state.readRegister("rdx") &* 10
                } else if symbol == "fzyMKs9kim0" {
                    // Event-queue waits pace the PS5 render loop at roughly one
                    // 60 Hz vblank while startup workers remain runnable.
                    requestedDelay = 166_667
                } else {
                    requestedDelay = 100_000
                }
                let delay = Int(min(max(requestedDelay, 50_000), 1_000_000))
                sleepingContexts.append(SleepingGuestContext(
                    context: RunnableGuestContext(
                        state: state,
                        threadHandle: activeThreadHandle
                    ),
                    wakeInstruction: currentInstruction + delay,
                    mutexToReacquire: conditionMutex == 0 ? nil : conditionMutex,
                    mutexDepth: mutexDepth
                ))
                let next = dequeueNextReadyContext(
                    from: &readyContexts,
                    joinWaiters: joinWaiters
                )
                state = next.state
                activeThreadHandle = next.threadHandle
                contextSwitchCount += 1
            }
        case "qj7QZpgr9Uw":
            // Unknown AGC command observed in Dreaming Sarah. SharpEmu and the
            // title both treat it as a single type-2 marker dword.
            guard let commandAddress = try allocateAGCCommandDwords(
                count: 1,
                commandBuffer: state.readRegister("rdi"),
                memory: &memory
            ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            try writeInteger(0x8000_0000, size: 4, to: commandAddress, memory: &memory)
            state.writeRegister("rax", value: commandAddress)
        case "tSBxhAPyytQ":
            // sceAgcDcbSetNumInstances.
            guard let commandAddress = try allocateAGCCommandDwords(
                count: 2,
                commandBuffer: state.readRegister("rdi"),
                memory: &memory
            ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            try writeInteger(
                agcPM4Header(lengthDwords: 2, opcode: 0x2F, register: 0),
                size: 4,
                to: commandAddress,
                memory: &memory
            )
            try writeInteger(state.readRegister("rsi"), size: 4, to: commandAddress + 4, memory: &memory)
            state.writeRegister("rax", value: commandAddress)
        case "n2fD4A+pb+g":
            // sceAgcCbSetShRegisterRangeDirect. GameMaker uses this immediately
            // before each menu draw to bind its vertex/texture descriptors and
            // small pixel constants, so preserving the direct SH packet is what
            // makes those resources visible to the submission renderer.
            let commandBuffer = state.readRegister("rdi")
            let registerOffset = state.readRegister("rsi") & 0xFFFF_FFFF
            let valuesAddress = state.readRegister("rdx")
            let valueCount = state.readRegister("rcx") & 0xFFFF_FFFF
            guard registerOffset > 0,
                  registerOffset <= 0x3FF,
                  valueCount > 0,
                  valueCount <= 4_096,
                  let markerAddress = try allocateAGCCommandDwords(
                    count: 2,
                    commandBuffer: commandBuffer,
                    memory: &memory
                  ),
                  let commandAddress = try allocateAGCCommandDwords(
                    count: valueCount + 2,
                    commandBuffer: commandBuffer,
                    memory: &memory
                  ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            try writeInteger(
                agcPM4Header(lengthDwords: 2, opcode: 0x10, register: 0),
                size: 4,
                to: markerAddress,
                memory: &memory
            )
            try writeInteger(0x6875_000D, size: 4, to: markerAddress + 4, memory: &memory)
            try writeInteger(
                agcPM4Header(lengthDwords: valueCount + 2, opcode: 0x76, register: 0),
                size: 4,
                to: commandAddress,
                memory: &memory
            )
            try writeInteger(registerOffset, size: 4, to: commandAddress + 4, memory: &memory)
            for index in 0..<valueCount {
                let value = valuesAddress == 0 ? 0 : try readInteger(
                    size: 4,
                    from: valuesAddress + index * 4,
                    memory: memory
                )
                try writeInteger(
                    value,
                    size: 4,
                    to: commandAddress + 8 + index * 4,
                    memory: &memory
                )
            }
            state.writeRegister("rax", value: commandAddress)
        case "Yw0jKSqop+E":
            // sceAgcDcbDrawIndexAuto. Gen5 serializes this as the AGC-specific
            // draw-auto NOP packet consumed by the submission renderer.
            guard state.readRegister("rdx") == 0x4000_0000,
                  let commandAddress = try allocateAGCCommandDwords(
                    count: 7,
                    commandBuffer: state.readRegister("rdi"),
                    memory: &memory
                  ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            try writeInteger(
                agcPM4Header(lengthDwords: 7, opcode: 0x10, register: 0x04),
                size: 4,
                to: commandAddress,
                memory: &memory
            )
            try writeInteger(state.readRegister("rsi"), size: 4, to: commandAddress + 4, memory: &memory)
            for index in 2..<7 {
                try writeInteger(0, size: 4, to: commandAddress + UInt64(index * 4), memory: &memory)
            }
            state.writeRegister("rax", value: commandAddress)
        case "aJf+j5yntiU":
            // sceAgcDcbEventWrite.
            let eventType = state.readRegister("rsi") & 0xFF
            guard eventType <= 0x3F,
                  state.readRegister("rdx") == 0,
                  let commandAddress = try allocateAGCCommandDwords(
                    count: 2,
                    commandBuffer: state.readRegister("rdi"),
                    memory: &memory
                  ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            try writeInteger(
                agcPM4Header(lengthDwords: 2, opcode: 0x46, register: 0),
                size: 4,
                to: commandAddress,
                memory: &memory
            )
            try writeInteger(eventType, size: 4, to: commandAddress + 4, memory: &memory)
            state.writeRegister("rax", value: commandAddress)
        case "57labkp+rSQ":
            // sceAgcDcbAcquireMem.
            let engine = state.readRegister("rsi") & 0xFF
            let cbDbOperation = state.readRegister("rdx") & 0xFFFF_FFFF
            let gcrControl = state.readRegister("rcx") & 0xFFFF_FFFF
            let baseAddress = state.readRegister("r8")
            let sizeBytes = state.readRegister("r9")
            let noSize = sizeBytes == UInt64.max
            let pollCycles = try readInteger(
                size: 4,
                from: state.readRegister("rsp") + 8,
                memory: memory
            )
            guard engine <= 1,
                  (baseAddress & 0xFF) == 0,
                  (baseAddress >> 40) == 0,
                  (noSize || ((sizeBytes & 0xFF) == 0 && (sizeBytes >> 40) == 0)),
                  let commandAddress = try allocateAGCCommandDwords(
                    count: 8,
                    commandBuffer: state.readRegister("rdi"),
                    memory: &memory
                  ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            let values: [UInt64] = [
                agcPM4Header(lengthDwords: 8, opcode: 0x10, register: 0x14),
                (engine << 31) | cbDbOperation,
                noSize ? 0 : sizeBytes >> 8,
                0,
                baseAddress >> 8,
                0,
                pollCycles / 40,
                gcrControl,
            ]
            for (index, value) in values.enumerated() {
                try writeInteger(value, size: 4, to: commandAddress + UInt64(index * 4), memory: &memory)
            }
            state.writeRegister("rax", value: commandAddress)
        case "UglJIZjGssM":
            // sceAgcDriverSubmitDcb. Decode the submitted PM4 packet envelope
            // now so the first Metal rasterizer can be implemented against the
            // title's observed command mix rather than a guessed full AGC ABI.
            let packetAddress = state.readRegister("rdi")
            guard packetAddress != 0 else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }
            let commandAddress = try readInteger(
                size: 8,
                from: packetAddress,
                memory: memory
            )
            let dwordCount = try readInteger(
                size: 4,
                from: packetAddress + 8,
                memory: memory
            )
            runtimeObjects["agc.submitCount", default: 0] += 1
            if runtimeObjects["content.layoutsLoaded"] == 1 {
                runtimeObjects["agc.menuSubmitCount", default: 0] += 1
            }
            runtimeObjects["agc.lastCommandAddress"] = commandAddress
            runtimeObjects["agc.lastDwordCount"] = dwordCount
            if commandAddress != 0, dwordCount > 0 {
                let summary = try summarizeAGCCommandBuffer(
                    address: commandAddress,
                    dwordCount: dwordCount,
                    memory: memory
                )
                runtimeObjects["agc.lastPacketCount"] = UInt64(summary.packetCount)
                runtimeObjects["agc.lastFlipPacketCount"] = UInt64(summary.flipPacketCount)
                let submitCount = runtimeObjects["agc.submitCount", default: 0]
                let menuSubmitCount = runtimeObjects["agc.menuSubmitCount", default: 0]
                if submitCount <= 3 ||
                    (runtimeObjects["content.layoutsLoaded"] == 1 &&
                        (menuSubmitCount <= 10 || dwordCount > 100)) {
                    recordRuntimeEvent(
                        "AGC DCB submit #\(submitCount)" +
                            (menuSubmitCount == 0 ? "" : " (menu #\(menuSubmitCount))") +
                            ": \(dwordCount) dwords, " +
                            "\(summary.packetCount) packets, " +
                            "\(summary.flipPacketCount) flip; " + summary.signatureText +
                            (summary.stateText.isEmpty ? "" : "; " + summary.stateText),
                        events: &runtimeEvents
                    )
                }
            }
            state.writeRegister("rax", value: 0)
            if stopAfterFirstAGCSubmit,
               runtimeObjects["agc.submitCount", default: 0] == 1 {
                return .halted("first AGC DCB submission reached")
            }
            if stopAfterMenuSubmit,
               runtimeObjects["content.layoutsLoaded"] == 1 {
                return .halted("first AGC DCB submission after menu layouts loaded")
            }
            if let stopAfterMenuSubmitCount,
               runtimeObjects["agc.menuSubmitCount", default: 0] >= stopAfterMenuSubmitCount {
                return .halted("AGC DCB menu submission #\(stopAfterMenuSubmitCount) reached")
            }
            if stopAfterFirstMenuDrawBatch,
               runtimeObjects["content.layoutsLoaded"] == 1,
               dwordCount > 100 {
                return .halted("first large AGC menu draw batch reached")
            }
        case "ZvwO9euwYzc", "-HOOCn0JY48", "hvUfkUIQcOE":
            // sceAgcDcbSet{Cx,Sh,Uc}RegistersIndirect.
            let packetRegister: UInt64 = switch symbol {
            case "ZvwO9euwYzc": 0x12
            case "-HOOCn0JY48": 0x11
            default: 0x13
            }
            let commandBuffer = state.readRegister("rdi")
            let registersAddress = state.readRegister("rsi")
            let registerCount = state.readRegister("rdx")
            guard let commandAddress = try allocateAGCCommandDwords(
                count: 4,
                commandBuffer: commandBuffer,
                memory: &memory
            ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            try writeInteger(
                agcPM4Header(lengthDwords: 4, opcode: 0x10, register: packetRegister),
                size: 4,
                to: commandAddress,
                memory: &memory
            )
            try writeInteger(registerCount, size: 4, to: commandAddress + 4, memory: &memory)
            try writeInteger(registersAddress, size: 4, to: commandAddress + 8, memory: &memory)
            try writeInteger(registersAddress >> 32, size: 4, to: commandAddress + 12, memory: &memory)
            state.writeRegister("rax", value: commandAddress)
        case "d-6uF9sZDIU", "z2duB-hHQSM", "vRoArM9zaIk":
            // sceAgcSet*RegIndirectPatchAddRegisters.
            let commandAddress = state.readRegister("rdi")
            if commandAddress != 0 {
                let currentCount = try readInteger(
                    size: 4,
                    from: commandAddress + 4,
                    memory: memory
                )
                try writeInteger(
                    currentCount + state.readRegister("rsi"),
                    size: 4,
                    to: commandAddress + 4,
                    memory: &memory
                )
            }
            state.writeRegister("rax", value: 0)
        case "vcmNN+AAXnY", "Qrj4c+61z4A", "6lNcCp+fxi4":
            // sceAgcSet*RegIndirectPatchSetAddress.
            let commandAddress = state.readRegister("rdi")
            let registersAddress = state.readRegister("rsi")
            if commandAddress != 0, registersAddress != 0 {
                try writeInteger(registersAddress, size: 4, to: commandAddress + 8, memory: &memory)
                try writeInteger(registersAddress >> 32, size: 4, to: commandAddress + 12, memory: &memory)
            }
            state.writeRegister("rax", value: 0)
        case "GIIW2J37e70":
            // sceAgcDcbSetIndexSize.
            guard let commandAddress = try allocateAGCCommandDwords(
                count: 2,
                commandBuffer: state.readRegister("rdi"),
                memory: &memory
            ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            try writeInteger(
                agcPM4Header(lengthDwords: 2, opcode: 0x2A, register: 0),
                size: 4,
                to: commandAddress,
                memory: &memory
            )
            try writeInteger(state.readRegister("rsi") & 0xFF, size: 4, to: commandAddress + 4, memory: &memory)
            state.writeRegister("rax", value: commandAddress)
        case "l4fM9K-Lyks":
            // sceAgcDcbSetIndexBuffer.
            guard let commandAddress = try allocateAGCCommandDwords(
                count: 5,
                commandBuffer: state.readRegister("rdi"),
                memory: &memory
            ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            let indexAddress = state.readRegister("rsi")
            try writeInteger(agcPM4Header(lengthDwords: 3, opcode: 0x26, register: 0), size: 4, to: commandAddress, memory: &memory)
            try writeInteger(indexAddress, size: 4, to: commandAddress + 4, memory: &memory)
            try writeInteger(indexAddress >> 32, size: 4, to: commandAddress + 8, memory: &memory)
            try writeInteger(agcPM4Header(lengthDwords: 2, opcode: 0x13, register: 0), size: 4, to: commandAddress + 12, memory: &memory)
            try writeInteger(state.readRegister("rdx"), size: 4, to: commandAddress + 16, memory: &memory)
            state.writeRegister("rax", value: commandAddress)
        case "B+aG9DUnTKA":
            // sceAgcDcbDrawIndexOffset.
            guard let commandAddress = try allocateAGCCommandDwords(
                count: 5,
                commandBuffer: state.readRegister("rdi"),
                memory: &memory
            ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            let indexCount = state.readRegister("rdx")
            try writeInteger(agcPM4Header(lengthDwords: 5, opcode: 0x35, register: 0), size: 4, to: commandAddress, memory: &memory)
            try writeInteger(indexCount, size: 4, to: commandAddress + 4, memory: &memory)
            try writeInteger(state.readRegister("rsi"), size: 4, to: commandAddress + 8, memory: &memory)
            try writeInteger(indexCount, size: 4, to: commandAddress + 12, memory: &memory)
            try writeInteger(state.readRegister("rcx") & 0xE000_0001, size: 4, to: commandAddress + 16, memory: &memory)
            state.writeRegister("rax", value: commandAddress)
        case "TRO721eVt4g":
            // sceAgcDcbResetQueue.
            guard let commandAddress = try allocateAGCCommandDwords(
                count: 2,
                commandBuffer: state.readRegister("rdi"),
                memory: &memory
            ) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            try writeInteger(
                agcPM4Header(lengthDwords: 2, opcode: 0x10, register: 0x05),
                size: 4,
                to: commandAddress,
                memory: &memory
            )
            try writeInteger(0, size: 4, to: commandAddress + 4, memory: &memory)
            state.writeRegister("rax", value: commandAddress)
        case "2JtWUUiYBXs", "wRbq6ZjNop4":
            // sceAgcGetRegisterDefaults2 and its internal variant. These
            // pointer tables are consumed by the guest's patch builder; an
            // empty approximation silently drops color-target and viewport
            // state from every submitted draw.
            let version = state.readRegister("rdi") & 0xFFFF_FFFF
            guard [UInt64(7), 8, 10, 13].contains(version) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            let key = symbol == "2JtWUUiYBXs"
                ? "agc.primaryRegisterDefaults"
                : "agc.internalRegisterDefaults"
            let defaults: UInt64
            if let cached = runtimeObjects[key], cached != 0 {
                defaults = cached
            } else if symbol == "2JtWUUiYBXs" {
                defaults = try allocateAGCRegisterDefaults(
                    groups: agcPrimaryRegisterDefaults,
                    cxTableLength: 78,
                    shTableLength: 19,
                    ucTableLength: 13,
                    memory: &memory,
                    heapCursor: &heapCursor,
                    allocations: &allocations
                )
                runtimeObjects[key] = defaults
            } else {
                defaults = try allocateAGCRegisterDefaults(
                    groups: agcInternalRegisterDefaults,
                    cxTableLength: 4,
                    shTableLength: 15,
                    ucTableLength: 3,
                    memory: &memory,
                    heapCursor: &heapCursor,
                    allocations: &allocations
                )
                runtimeObjects[key] = defaults
            }
            state.writeRegister("rax", value: defaults)
        case "D9sr1xGUriE":
            // sceAgcCreatePrimState copies the geometry shader's special
            // register pairs into the caller's CX/UC blocks and appends the
            // requested primitive type.
            let cxRegisters = state.readRegister("rdi")
            let ucRegisters = state.readRegister("rsi")
            let hullShader = state.readRegister("rdx")
            let geometryShader = state.readRegister("rcx")
            let primitiveType = state.readRegister("r8") & 0xFFFF_FFFF
            guard cxRegisters != 0,
                  ucRegisters != 0,
                  hullShader == 0,
                  geometryShader != 0 else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }
            let shaderType = try readInteger(
                size: 1,
                from: geometryShader + 0x5A,
                memory: memory
            )
            let specials = try readInteger(
                size: 8,
                from: geometryShader + 0x28,
                memory: memory
            )
            guard [UInt64(2), 4, 6].contains(shaderType), specials != 0 else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }
            try writeInteger(
                readInteger(size: 8, from: specials + 0x08, memory: memory),
                size: 8,
                to: cxRegisters,
                memory: &memory
            )
            try writeInteger(
                readInteger(size: 8, from: specials + 0x20, memory: memory),
                size: 8,
                to: cxRegisters + 8,
                memory: &memory
            )
            try writeInteger(
                readInteger(size: 8, from: specials, memory: memory),
                size: 8,
                to: ucRegisters,
                memory: &memory
            )
            try writeInteger(
                readInteger(size: 8, from: specials + 0x28, memory: memory),
                size: 8,
                to: ucRegisters + 8,
                memory: &memory
            )
            try writeInteger(0x242, size: 4, to: ucRegisters + 16, memory: &memory)
            try writeInteger(primitiveType, size: 4, to: ucRegisters + 20, memory: &memory)
            state.writeRegister("rax", value: 0)
        case "HV4j+E0MBHE":
            // sceAgcCreateInterpolantMapping emits all 32 SPI PS input
            // controls, preserving the flat-interpolation bit from the pixel
            // shader's input semantics.
            let registers = state.readRegister("rdi")
            let geometryShader = state.readRegister("rsi")
            let pixelShader = state.readRegister("rdx")
            guard registers != 0, geometryShader != 0 else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }
            let outputSemantics = try readInteger(
                size: 8,
                from: geometryShader + 0x38,
                memory: memory
            )
            let outputSemanticCount = try readInteger(
                size: 4,
                from: geometryShader + 0x56,
                memory: memory
            )
            let inputSemantics = pixelShader == 0 ? 0 : try readInteger(
                size: 8,
                from: pixelShader + 0x30,
                memory: memory
            )
            for semanticIndex: UInt64 in 0..<32 {
                var value: UInt64 = 0
                if semanticIndex < outputSemanticCount, outputSemantics != 0 {
                    var flat = false
                    if inputSemantics != 0 {
                        let inputSemantic = try readInteger(
                            size: 4,
                            from: inputSemantics + semanticIndex * 4,
                            memory: memory
                        )
                        flat = ((inputSemantic >> 22) & 1) != 0
                    }
                    value = semanticIndex | (flat ? 0x400 : 0)
                }
                let destination = registers + semanticIndex * 8
                try writeInteger(0x191 + semanticIndex, size: 4, to: destination, memory: &memory)
                try writeInteger(value, size: 4, to: destination + 4, memory: &memory)
            }
            state.writeRegister("rax", value: 0)
        case "f3dg2CSgRKY":
            // sceAgcCreateShader relocates the pointer fields embedded in the
            // serialized AGC header, binds the separately allocated code, and
            // returns the live header through the caller-provided destination.
            let destination = state.readRegister("rdi")
            let header = state.readRegister("rsi")
            let code = state.readRegister("rdx")
            guard destination != 0, header != 0, code != 0 else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }

            let fileHeader = try readInteger(size: 4, from: header, memory: memory)
            let version = try readInteger(size: 4, from: header + 4, memory: memory)
            guard fileHeader == 0x3433_3231, version == 0x18 else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }

            for fieldOffset: UInt64 in [0x18, 0x20, 0x08, 0x28, 0x30, 0x38] {
                let fieldAddress = header + fieldOffset
                let relative = try readInteger(size: 8, from: fieldAddress, memory: memory)
                if relative != 0 {
                    try writeInteger(
                        fieldAddress + relative,
                        size: 8,
                        to: fieldAddress,
                        memory: &memory
                    )
                }
            }
            try writeInteger(code, size: 8, to: header + 0x10, memory: &memory)

            let userData = try readInteger(size: 8, from: header + 0x08, memory: memory)
            if userData != 0 {
                for fieldOffset: UInt64 in [0x00, 0x08, 0x10, 0x18, 0x20] {
                    let fieldAddress = userData + fieldOffset
                    let relative = try readInteger(size: 8, from: fieldAddress, memory: memory)
                    if relative != 0 {
                        try writeInteger(
                            fieldAddress + relative,
                            size: 8,
                            to: fieldAddress,
                            memory: &memory
                        )
                    }
                }
            }

            let shRegisters = try readInteger(size: 8, from: header + 0x20, memory: memory)
            let registerCount = try readInteger(size: 1, from: header + 0x5C, memory: memory)
            if shRegisters != 0, registerCount >= 2 {
                try writeInteger(
                    (code >> 8) & 0xFFFF_FFFF,
                    size: 4,
                    to: shRegisters + 4,
                    memory: &memory
                )
                try writeInteger(
                    (code >> 40) & 0xFF,
                    size: 4,
                    to: shRegisters + 12,
                    memory: &memory
                )
            }
            try writeInteger(header, size: 8, to: destination, memory: &memory)
            state.writeRegister("rax", value: 0)
        case "Up36PTk687E":
            // sceVideoOutOpen returns a positive port handle.
            state.writeRegister("rax", value: 1)
        case "PjS5uASwcV8":
            // SceVideoOutBufferAttribute2 (0x40 bytes).
            let attribute = state.readRegister("rdi")
            guard attribute != 0 else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }
            try memory.write(Data(count: 0x40), at: attribute)
            try writeInteger(state.readRegister("rdx"), size: 4, to: attribute + 0x04, memory: &memory)
            try writeInteger(state.readRegister("rcx"), size: 4, to: attribute + 0x0C, memory: &memory)
            try writeInteger(state.readRegister("r8"), size: 4, to: attribute + 0x10, memory: &memory)
            try writeInteger(state.readRegister("r9"), size: 8, to: attribute + 0x18, memory: &memory)
            try writeInteger(state.readRegister("rsi"), size: 8, to: attribute + 0x20, memory: &memory)
            runtimeObjects["videoout.attribute"] = attribute
            runtimeObjects["videoout.width"] = state.readRegister("rcx")
            runtimeObjects["videoout.height"] = state.readRegister("r8")
            runtimeObjects["videoout.pixelFormat"] = state.readRegister("rsi")
            state.writeRegister("rax", value: 0)
        case "rKBUtgRrtbk":
            // sceVideoOutRegisterBuffers2 receives a packed array of 64-bit
            // color-buffer addresses. Preserve both sides of the swap chain.
            let setIndex = state.readRegister("rsi")
            let firstBuffer = state.readRegister("rdx")
            let entries = state.readRegister("rcx")
            let bufferCount = min(state.readRegister("r8"), 16)
            var registeredAddresses: [UInt64] = []
            var rawBufferWords: [UInt64] = []
            var backingAllocations: [String] = []
            if entries != 0 {
                for index in 0..<min(bufferCount * 2, 8) {
                    rawBufferWords.append(try readInteger(
                        size: 8,
                        from: entries + index * 8,
                        memory: memory
                    ))
                }
                for index in 0..<bufferCount {
                    let colorAddress = try readInteger(
                        size: 8,
                        from: entries + index * 8,
                        memory: memory
                    )
                    registeredAddresses.append(colorAddress)
                    if colorAddress != 0,
                       let allocation = allocations.first(where: { base, size in
                           colorAddress >= base && colorAddress < base + size
                       }) {
                        backingAllocations.append(
                            "\(allocation.key.hexadecimal)+\(allocation.value)"
                        )
                    } else {
                        backingAllocations.append("none")
                    }
                    runtimeObjects["videoout.buffer.\(firstBuffer + index)"] = colorAddress
                }
            }
            recordRuntimeEvent(
                "VideoOut registered \(bufferCount) buffer(s) in set \(setIndex): " +
                    registeredAddresses.map(\.hexadecimal).joined(separator: ", ") +
                    " raw " + rawBufferWords.map(\.hexadecimal).joined(separator: ", ") +
                    " allocations " + backingAllocations.joined(separator: ", ") +
                    " size \(runtimeObjects["videoout.width", default: 0])x" +
                    "\(runtimeObjects["videoout.height", default: 0]) format " +
                    "\(runtimeObjects["videoout.pixelFormat", default: 0].hexadecimal)",
                events: &runtimeEvents
            )
            state.writeRegister("rax", value: setIndex)
        case "YUeqkyT7mEQ":
            // sceAgcDcbSetFlip encodes the Gen5 flip inside an AGC command
            // buffer instead of calling sceVideoOutSubmitFlip directly.
            let commandBuffer = state.readRegister("rdi")
            let bufferIndex = state.readRegister("rdx")
            let flipMode = state.readRegister("rcx")
            let flipArgument = state.readRegister("r8")
            var commandAddress: UInt64 = 0
            if commandBuffer != 0 {
                let cursorUp = try readInteger(
                    size: 8,
                    from: commandBuffer + 0x10,
                    memory: memory
                )
                let cursorDown = try readInteger(
                    size: 8,
                    from: commandBuffer + 0x18,
                    memory: memory
                )
                if cursorUp != 0, cursorDown >= cursorUp + 24 {
                    commandAddress = cursorUp
                    try writeInteger(
                        cursorUp + 24,
                        size: 8,
                        to: commandBuffer + 0x10,
                        memory: &memory
                    )
                    // PM4 type-3 NOP packet, six dwords, RFlip payload 0x17.
                    try writeInteger(0xC004_105C, size: 4, to: cursorUp, memory: &memory)
                    try writeInteger(state.readRegister("rsi"), size: 4, to: cursorUp + 4, memory: &memory)
                    try writeInteger(bufferIndex, size: 4, to: cursorUp + 8, memory: &memory)
                    try writeInteger(flipMode, size: 4, to: cursorUp + 12, memory: &memory)
                    try writeInteger(flipArgument, size: 4, to: cursorUp + 16, memory: &memory)
                    try writeInteger(flipArgument >> 32, size: 4, to: cursorUp + 20, memory: &memory)
                }
            }
            runtimeObjects["videoout.currentBuffer"] = bufferIndex
            runtimeObjects["videoout.flipCount", default: 0] += 1
            let colorAddress = runtimeObjects["videoout.buffer.\(bufferIndex)", default: 0]
            recordRuntimeEvent(
                "VideoOut AGC flip #\(runtimeObjects["videoout.flipCount", default: 0]) " +
                    "buffer \(Int64(bitPattern: bufferIndex)) " +
                    "address \(colorAddress.hexadecimal) mode \(flipMode) " +
                    "arg \(flipArgument)",
                events: &runtimeEvents
            )
            publishVideoFrameIfNeeded(memory: memory, runtimeObjects: runtimeObjects)
            let reachedDiagnosticFlip =
                (stopAfterFirstAGCFlip && runtimeObjects["videoout.flipCount", default: 0] == 1) ||
                (stopAfterMenuFlip && runtimeObjects["content.layoutsLoaded"] == 1)
            if reachedDiagnosticFlip, colorAddress != 0 {
                let width = runtimeObjects["videoout.width", default: 0]
                let height = runtimeObjects["videoout.height", default: 0]
                let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
                let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
                if !pixelOverflow, !byteOverflow, byteCount <= UInt64(Int.max) {
                    let frame = try memory.readIgnoringProtection(
                        at: colorAddress,
                        length: Int(byteCount)
                    )
                    let nonzeroByteCount = frame.reduce(into: 0) { count, byte in
                        if byte != 0 { count += 1 }
                    }
                    recordRuntimeEvent(
                        "VideoOut frame sample: \(frame.count) bytes, " +
                            "\(nonzeroByteCount) nonzero",
                        events: &runtimeEvents
                    )
                }
            }
            state.writeRegister("rax", value: commandAddress)
            if stopAfterFirstAGCFlip,
               runtimeObjects["videoout.flipCount", default: 0] == 1 {
                return .halted("first AGC VideoOut flip reached")
            }
            if stopAfterMenuFlip,
               runtimeObjects["content.layoutsLoaded"] == 1 {
                return .halted("first AGC VideoOut flip after menu layouts loaded")
            }
        case "U46NwOiJpys":
            // sceVideoOutSubmitFlip
            let bufferIndex = state.readRegister("rsi")
            runtimeObjects["videoout.currentBuffer"] = bufferIndex
            runtimeObjects["videoout.flipCount", default: 0] += 1
            recordRuntimeEvent(
                "VideoOut flip #\(runtimeObjects["videoout.flipCount", default: 0]) "
                    + "buffer \(Int64(bitPattern: bufferIndex)) mode \(state.readRegister("rdx")) "
                    + "arg \(state.readRegister("rcx"))",
                events: &runtimeEvents
            )
            publishVideoFrameIfNeeded(memory: memory, runtimeObjects: runtimeObjects)
            state.writeRegister("rax", value: 0)
        case "CBiu4mCE1DA", "HXzjK9yI30k", "zgXifHT9ErY":
            // Flip-rate/event registration and pending checks are successful
            // while the cooperative host presenter remains non-blocking.
            state.writeRegister("rax", value: 0)
        case "SbU3dwp80lQ":
            // SceVideoOutFlipStatus (0x28 bytes).
            let status = state.readRegister("rsi")
            if status != 0 {
                try memory.write(Data(count: 0x28), at: status)
                try writeInteger(
                    runtimeObjects["videoout.flipCount", default: 0],
                    size: 8,
                    to: status,
                    memory: &memory
                )
                try writeInteger(
                    runtimeObjects["videoout.currentBuffer", default: 0],
                    size: 8,
                    to: status + 0x20,
                    memory: &memory
                )
            }
            state.writeRegister("rax", value: 0)
        case "tIhsqj0qsFE", "z+P+xCnWLBk", "Vla-Z+eXlxo", "MLWl90SFWNE":
            state.writeRegister("rax", value: 0)
        case "xeYO4u7uyJ0":
            // fopen: expose read-only files from the selected title's app root.
            let guestPath = try guestString(at: state.readRegister("rdi"), memory: memory)
            guard let fileURL = resolveGuestFileURL(guestPath),
                  let sourceData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
                recordRuntimeEvent("fopen missing: \(guestPath)", events: &runtimeEvents)
                state.writeRegister("rax", value: 0)
                return nil
            }
            var data = sourceData
            if guestPath.hasSuffix("/data.js"),
               let menuPayload = makeDreamingSarahMenuBootPayload(from: sourceData) {
                data = menuPayload.data
                recordRuntimeEvent(
                    "menu boot payload: data.js \(menuPayload.jsonSize) JSON bytes, " +
                    "padded to \(menuPayload.data.count)",
                    events: &runtimeEvents
                )
            }
            let handle = allocateGuestMemory(
                size: 16,
                alignment: 16,
                heapCursor: &heapCursor,
                allocations: &allocations
            )
            openFiles[handle] = GuestOpenFile(data: data, offset: 0)
            if guestPath.hasSuffix("/data.js") {
                runtimeObjects["scheduler.startupContentThread"] = activeThreadHandle
                let event = "Scheduler boosted data.js loader thread \(activeThreadHandle.hexadecimal)"
                if !runtimeEvents.contains(event) {
                    recordRuntimeEvent(event, events: &runtimeEvents)
                }
            }
            recordRuntimeEvent(
                "fopen read: \(guestPath) (\(data.count) bytes)",
                events: &runtimeEvents
            )
            state.writeRegister("rax", value: handle)
        case "lbB+UlZqVG0":
            // fread(destination, elementSize, elementCount, FILE *)
            let destination = state.readRegister("rdi")
            let elementSize = state.readRegister("rsi")
            let elementCount = state.readRegister("rdx")
            let handle = state.readRegister("rcx")
            guard destination != 0, elementSize > 0, var file = openFiles[handle] else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            let (requested, overflow) = elementSize.multipliedReportingOverflow(by: elementCount)
            guard !overflow, requested <= UInt64(Int.max) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            let remaining = max(file.data.count - file.offset, 0)
            let byteCount = min(Int(requested), remaining)
            if byteCount > 0 {
                try memory.write(
                    file.data.subdata(in: file.offset..<(file.offset + byteCount)),
                    at: destination
                )
                file.offset += byteCount
                openFiles[handle] = file
            }
            recordRuntimeEvent("fread: \(byteCount) bytes", events: &runtimeEvents)
            state.writeRegister("rax", value: UInt64(byteCount) / elementSize)
        case "rQFVBXp-Cxg":
            // fseek(FILE *, signedOffset, origin)
            let handle = state.readRegister("rdi")
            guard var file = openFiles[handle] else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }
            let offset = Int64(bitPattern: state.readRegister("rsi"))
            let origin = state.readRegister("rdx")
            let base: Int64
            switch origin {
            case 0: base = 0
            case 1: base = Int64(file.offset)
            case 2: base = Int64(file.data.count)
            default:
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }
            let (candidate, didOverflow) = base.addingReportingOverflow(offset)
            guard !didOverflow, candidate >= 0, candidate <= Int64(file.data.count) else {
                state.writeRegister("rax", value: UInt64.max)
                return nil
            }
            file.offset = Int(candidate)
            openFiles[handle] = file
            state.writeRegister("rax", value: 0)
        case "Qazy8LmXTvw":
            let handle = state.readRegister("rdi")
            if let file = openFiles[handle] {
                state.writeRegister("rax", value: UInt64(file.offset))
            } else {
                state.writeRegister("rax", value: UInt64.max)
            }
        case "3QIPIh-GDjw":
            let handle = state.readRegister("rdi")
            if var file = openFiles[handle] {
                file.offset = 0
                openFiles[handle] = file
            }
            state.writeRegister("rax", value: 0)
        case "LxcEU+ICu8U":
            let handle = state.readRegister("rdi")
            let reachedEnd = openFiles[handle].map { $0.offset >= $0.data.count } ?? true
            state.writeRegister("rax", value: reachedEnd ? 1 : 0)
        case "AHxyhN96dy4":
            state.writeRegister("rax", value: 0)
        case "uodLYyUip20":
            openFiles.removeValue(forKey: state.readRegister("rdi"))
            state.writeRegister("rax", value: 0)
        case "1uJgoVq3bQU", "rcQCUr0EaRU":
            // Dinkumware _Getptolower / _Getptoupper return a pointer to
            // the locale table pointer. Each table is indexed by a signed
            // byte range (-128...255) and stores 16-bit character mappings.
            if let holder = runtimeObjects[symbol] {
                state.writeRegister("rax", value: holder)
                return nil
            }
            let convertToLower = symbol == "1uJgoVq3bQU"
            let storage = allocateGuestMemory(
                size: 384 * 2,
                alignment: 16,
                heapCursor: &heapCursor,
                allocations: &allocations
            )
            var table = Data(count: 384 * 2)
            for character in -128...255 {
                var mapped = character
                if convertToLower, character >= 65, character <= 90 {
                    mapped += 32
                } else if !convertToLower, character >= 97, character <= 122 {
                    mapped -= 32
                }
                let value = UInt16(bitPattern: Int16(mapped))
                let offset = (character + 128) * 2
                table[offset] = UInt8(truncatingIfNeeded: value)
                table[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            }
            try memory.write(table, at: storage)
            let tablePointer = storage + 128 * 2
            let holder = allocateGuestMemory(
                size: 8,
                alignment: 8,
                heapCursor: &heapCursor,
                allocations: &allocations
            )
            try writeInteger(tablePointer, size: 8, to: holder, memory: &memory)
            runtimeObjects[symbol] = holder
            state.writeRegister("rax", value: holder)
        case "j4ViWNHEgww":
            state.writeRegister("rax", value: try guestStringLength(
                at: state.readRegister("rdi"),
                memory: memory
            ))
        case "8zTFvBIAIN8":
            let destination = state.readRegister("rdi")
            let count = state.readRegister("rdx")
            if count <= UInt64(Int.max) {
                try memory.write(
                    Data(repeating: UInt8(truncatingIfNeeded: state.readRegister("rsi")), count: Int(count)),
                    at: destination
                )
            }
            state.writeRegister("rax", value: destination)
        case "Q3VBxCXhUHs", "+P6FRGH4LfA":
            let destination = state.readRegister("rdi")
            let source = state.readRegister("rsi")
            let count = state.readRegister("rdx")
            if count <= UInt64(Int.max) {
                let bytes = try memory.read(at: source, length: Int(count))
                try memory.write(bytes, at: destination)
            }
            state.writeRegister("rax", value: destination)
        case "DfivPArhucg":
            let lhs = state.readRegister("rdi")
            let rhs = state.readRegister("rsi")
            let count = state.readRegister("rdx")
            guard count <= UInt64(Int.max) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            let left = try memory.read(at: lhs, length: Int(count))
            let right = try memory.read(at: rhs, length: Int(count))
            var comparison: Int64 = 0
            for index in 0..<Int(count) where left[index] != right[index] {
                comparison = Int64(left[index]) - Int64(right[index])
                break
            }
            state.writeRegister("rax", value: UInt64(bitPattern: comparison))
        case "kiZSXIWd9vg":
            let destination = state.readRegister("rdi")
            let source = state.readRegister("rsi")
            let count = try guestStringLength(at: source, memory: memory) + 1
            if count <= UInt64(Int.max) {
                try memory.write(try memory.read(at: source, length: Int(count)), at: destination)
            }
            state.writeRegister("rax", value: destination)
        case "Ls4tzzhimqQ":
            let destination = state.readRegister("rdi")
            let source = state.readRegister("rsi")
            let destinationLength = try guestStringLength(at: destination, memory: memory)
            let sourceLength = try guestStringLength(at: source, memory: memory)
            if destinationLength + sourceLength + 1 <= UInt64(Int.max) {
                try memory.write(
                    try memory.read(at: source, length: Int(sourceLength + 1)),
                    at: destination + destinationLength
                )
            }
            state.writeRegister("rax", value: destination)
        case "SfQIZcqvvms":
            let destination = state.readRegister("rdi")
            let source = state.readRegister("rsi")
            let capacity = state.readRegister("rdx")
            let sourceLength = try guestStringLength(at: source, memory: memory)
            if capacity > 0 {
                let copyLength = min(sourceLength, capacity - 1)
                if copyLength > 0, copyLength <= UInt64(Int.max) {
                    try memory.write(
                        try memory.read(at: source, length: Int(copyLength)),
                        at: destination
                    )
                }
                try memory.write(Data([0]), at: destination + copyLength)
            }
            state.writeRegister("rax", value: sourceLength)
        case "6sJWiWSRuqk":
            let destination = state.readRegister("rdi")
            let source = state.readRegister("rsi")
            let capacity = state.readRegister("rdx")
            let sourceLength = try guestStringLength(at: source, memory: memory)
            let copyLength = min(sourceLength, capacity)
            guard capacity <= UInt64(Int.max), copyLength <= UInt64(Int.max) else {
                state.writeRegister("rax", value: destination)
                return nil
            }
            if copyLength > 0 {
                try memory.write(
                    try memory.read(at: source, length: Int(copyLength)),
                    at: destination
                )
            }
            if capacity > copyLength {
                try memory.write(
                    Data(repeating: 0, count: Int(capacity - copyLength)),
                    at: destination + copyLength
                )
            }
            state.writeRegister("rax", value: destination)
        case "Ovb2dSJOAuE", "aesyjrHVWy4", "AV6ipCNa4Rw", "pXvbDfchu6k":
            let lhs = state.readRegister("rdi")
            let rhs = state.readRegister("rsi")
            let lhsLength = try guestStringLength(at: lhs, memory: memory)
            let rhsLength = try guestStringLength(at: rhs, memory: memory)
            let requested = symbol == "aesyjrHVWy4" || symbol == "pXvbDfchu6k"
                ? state.readRegister("rdx")
                : UInt64.max
            let ignoreCase = symbol == "AV6ipCNa4Rw" || symbol == "pXvbDfchu6k"
            let comparedLength = min(max(lhsLength, rhsLength) + 1, requested)
            guard comparedLength <= UInt64(Int.max) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            var comparison: Int64 = 0
            for offset in 0..<Int(comparedLength) {
                var left = offset < Int(lhsLength)
                    ? try memory.read(at: lhs + UInt64(offset), length: 1)[0]
                    : 0
                var right = offset < Int(rhsLength)
                    ? try memory.read(at: rhs + UInt64(offset), length: 1)[0]
                    : 0
                if ignoreCase {
                    if left >= 65, left <= 90 { left += 32 }
                    if right >= 65, right <= 90 { right += 32 }
                }
                if left != right {
                    comparison = Int64(left) - Int64(right)
                    break
                }
            }
            state.writeRegister("rax", value: UInt64(bitPattern: comparison))
        case "9BcDykPmo1I":
            // libKernel __error: each cooperative guest thread has its own TLS
            // block, so this is a naturally thread-local writable errno slot.
            state.writeRegister("rax", value: state.fsBase + 0x100)
        case "9UK1vLZQft4", "7H0iTOciTLo":
            // scePthreadMutexLock / pthread_mutex_lock. Contending cooperative
            // threads are parked until unlock transfers ownership to them.
            let mutex = state.readRegister("rdi")
            if var mutexState = mutexStates[mutex] {
                if mutexState.owner == activeThreadHandle {
                    mutexState.depth += 1
                    mutexStates[mutex] = mutexState
                    state.writeRegister("rax", value: 0)
                } else if !readyContexts.isEmpty {
                    state.writeRegister("rax", value: 0)
                    mutexWaiters[mutex, default: []].append(GuestMutexWaiter(
                        context: RunnableGuestContext(
                            state: state,
                            threadHandle: activeThreadHandle
                        ),
                        depth: 1
                    ))
                    let next = dequeueNextReadyContext(
                        from: &readyContexts,
                        joinWaiters: joinWaiters
                    )
                    state = next.state
                    activeThreadHandle = next.threadHandle
                    contextSwitchCount += 1
                } else {
                    recordRuntimeEvent(
                        "mutex deadlock: \(mutex.hexadecimal) owner " +
                            "\(mutexState.owner.hexadecimal) waiter " +
                            "\(activeThreadHandle.hexadecimal)",
                        events: &runtimeEvents
                    )
                    return .halted("guest mutex wait has no runnable owner")
                }
            } else {
                mutexStates[mutex] = GuestMutexState(
                    owner: activeThreadHandle,
                    depth: 1
                )
                state.writeRegister("rax", value: 0)
            }
        case "tn3VlD0hG60", "2Z+PpY6CaJg":
            // scePthreadMutexUnlock / pthread_mutex_unlock.
            let mutex = state.readRegister("rdi")
            if var mutexState = mutexStates[mutex],
               mutexState.owner == activeThreadHandle,
               mutexState.depth > 0 {
                if mutexState.depth > 1 {
                    mutexState.depth -= 1
                    mutexStates[mutex] = mutexState
                } else if var waiters = mutexWaiters[mutex], !waiters.isEmpty {
                    let waiter = waiters.removeFirst()
                    if waiters.isEmpty {
                        mutexWaiters.removeValue(forKey: mutex)
                    } else {
                        mutexWaiters[mutex] = waiters
                    }
                    mutexStates[mutex] = GuestMutexState(
                        owner: waiter.context.threadHandle,
                        depth: waiter.depth
                    )
                    var waiterState = waiter.context.state
                    waiterState.writeRegister("rax", value: 0)
                    readyContexts.append(RunnableGuestContext(
                        state: waiterState,
                        threadHandle: waiter.context.threadHandle
                    ))
                } else {
                    mutexStates.removeValue(forKey: mutex)
                }
                state.writeRegister("rax", value: 0)
            } else {
                state.writeRegister("rax", value: 1)
            }
        case "dhK16CKwhQg":
            // isfinite(double). The guest passes the scalar in XMM0 and
            // rejects the JSON number when this predicate returns zero.
            let bytes = try state.readVectorRegister("xmm0", byteCount: 8)
            var bits: UInt64 = 0
            for index in 0..<bytes.count {
                bits |= UInt64(bytes[index]) << UInt64(index * 8)
            }
            state.writeRegister("eax", value: Double(bitPattern: bits).isFinite ? 1 : 0)
        case "2vDqwBlpF-o":
            // strtod. Returning only RAX is not sufficient for floating-point
            // results: the SysV ABI returns the parsed value in XMM0, and the
            // JSON loader also requires endptr to reach the token boundary.
            let parsed = try parseGuestDouble(
                at: state.readRegister("rdi"),
                memory: memory
            )
            let endPointer = state.readRegister("rsi")
            if endPointer != 0 {
                try writeInteger(parsed.endAddress, size: 8, to: endPointer, memory: &memory)
            }
            if parsed.rangeError {
                try writeInteger(34, size: 4, to: state.fsBase + 0x100, memory: &memory)
            }
            var bits = parsed.value.bitPattern.littleEndian
            var result = try state.readVectorRegister("xmm0", byteCount: 16)
            result.replaceSubrange(0..<8, with: Data(bytes: &bits, count: 8))
            try state.writeVectorRegister("xmm0", bytes: result, byteCount: 16)
            state.writeRegister("rax", value: 0)
        case "8u8lPzUEq+U":
            // memchr, used by the JSON string decoder to locate escapes.
            let start = state.readRegister("rdi")
            let needle = UInt8(truncatingIfNeeded: state.readRegister("rsi"))
            let count = state.readRegister("rdx")
            guard start != 0, count > 0 else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            guard count <= UInt64(Int.max) else {
                state.writeRegister("rax", value: 0)
                return nil
            }
            let bytes = try memory.read(at: start, length: Int(count))
            if let offset = bytes.firstIndex(of: needle) {
                state.writeRegister("rax", value: start + UInt64(offset))
            } else {
                state.writeRegister("rax", value: 0)
            }
        case "5OqszGpy7Mg", "VOBg+iNwB-4":
            // Signed/unsigned long integer parsers used by the title's JSON
            // loader. PS4/PS5 long values use the 64-bit SysV ABI.
            let parsed = try parseGuestInteger(
                at: state.readRegister("rdi"),
                requestedBase: state.readRegister("rdx"),
                signed: symbol == "5OqszGpy7Mg",
                memory: memory
            )
            let endPointer = state.readRegister("rsi")
            if endPointer != 0 {
                try writeInteger(parsed.endAddress, size: 8, to: endPointer, memory: &memory)
            }
            if parsed.overflow {
                try writeInteger(34, size: 4, to: state.fsBase + 0x100, memory: &memory)
            }
            state.writeRegister("rax", value: parsed.value)
        case "Q2V+iqvjgC0", "eLdDw6l0-bU":
            let destination = state.readRegister("rdi")
            let capacity = state.readRegister("rsi")
            let formatAddress = state.readRegister("rdx")
            let format = try guestString(at: formatAddress, memory: memory)
            let formatted = symbol == "Q2V+iqvjgC0"
                ? try formatGuestVariadicString(
                    format,
                    vaListAddress: state.readRegister("rcx"),
                    memory: memory
                )
                : try formatGuestRegisterVariadicString(
                    format,
                    registerArguments: [
                        state.readRegister("rcx"),
                        state.readRegister("r8"),
                        state.readRegister("r9")
                    ],
                    stackAddress: state.readRegister("rsp"),
                    memory: memory
                )
            let bytes = Data(formatted.utf8)
            if destination != 0, capacity > 0 {
                let copyCount = min(UInt64(bytes.count), capacity - 1)
                if copyCount > 0 {
                    try memory.write(bytes.prefix(Int(copyCount)), at: destination)
                }
                try memory.write(Data([0]), at: destination + copyCount)
            }
            if formatted.contains("Done loading event sheets & layouts") {
                runtimeObjects["content.layoutsLoaded"] = 1
            }
            recordRuntimeEvent("guest format: \(formatted)", events: &runtimeEvents)
            state.writeRegister("rax", value: UInt64(bytes.count))
        case "tcVi5SivF7Q":
            let destination = state.readRegister("rdi")
            let format = try guestString(at: state.readRegister("rsi"), memory: memory)
            let formatted = try formatGuestRegisterVariadicString(
                format,
                registerArguments: [
                    state.readRegister("rdx"),
                    state.readRegister("rcx"),
                    state.readRegister("r8"),
                    state.readRegister("r9")
                ],
                stackAddress: state.readRegister("rsp"),
                memory: memory
            )
            var bytes = Data(formatted.utf8)
            bytes.append(0)
            try memory.write(bytes, at: destination)
            state.writeRegister("rax", value: UInt64(bytes.count - 1))
        case "hcuQgD53UxM":
            let format = try guestString(at: state.readRegister("rdi"), memory: memory)
            let text = try formatGuestRegisterVariadicString(
                format,
                registerArguments: [
                    state.readRegister("rsi"),
                    state.readRegister("rdx"),
                    state.readRegister("rcx"),
                    state.readRegister("r8"),
                    state.readRegister("r9")
                ],
                stackAddress: state.readRegister("rsp"),
                memory: memory
            )
            if text.contains("Done loading event sheets & layouts") {
                runtimeObjects["content.layoutsLoaded"] = 1
            }
            recordRuntimeEvent("guest log: \(text)", events: &runtimeEvents)
            state.writeRegister("rax", value: UInt64(text.utf8.count))
        case "YQ0navp+YIc":
            let text = try guestString(at: state.readRegister("rdi"), memory: memory)
            recordRuntimeEvent("guest log: \(text)", events: &runtimeEvents)
            state.writeRegister("rax", value: UInt64(text.utf8.count))
        case "QrZZdJ8XsX0":
            let text = try guestString(at: state.readRegister("rdi"), memory: memory)
            recordRuntimeEvent("guest log: \(text)", events: &runtimeEvents)
            state.writeRegister("rax", value: 0)
        case "3GPpjQdAMTw":
            let guardAddress = state.readRegister("rdi")
            let value = try memory.read(at: guardAddress, length: 1)[0]
            if value == 0 {
                try memory.write(Data([1]), at: guardAddress)
                state.writeRegister("rax", value: 1)
            } else {
                state.writeRegister("rax", value: 0)
            }
        case "9rAeANT2tyE":
            state.writeRegister("rax", value: 0)
        case "uMei1W9uyNo":
            let exitCode = state.readRegister("rdi")
            // Some ports invoke process-wide exit from a background media
            // worker when an optional preload fails. Once the title has a
            // live menu, isolate that worker like pthread_exit so the render,
            // input, and audio threads can continue in a degraded state.
            if runtimeObjects["content.layoutsLoaded"] == 1,
               !readyContexts.isEmpty {
                recordRuntimeEvent(
                    "isolated guest exit(\(exitCode)) on thread \(activeThreadHandle.hexadecimal)",
                    events: &runtimeEvents
                )
                threadReturnValues[activeThreadHandle] = exitCode
                if let waiters = joinWaiters.removeValue(forKey: activeThreadHandle) {
                    for waiter in waiters {
                        if waiter.resultAddress != 0 {
                            try writeInteger(
                                exitCode,
                                size: 8,
                                to: waiter.resultAddress,
                                memory: &memory
                            )
                        }
                        var waiterState = waiter.context.state
                        waiterState.writeRegister("rax", value: 0)
                        readyContexts.append(RunnableGuestContext(
                            state: waiterState,
                            threadHandle: waiter.context.threadHandle
                        ))
                    }
                }
                let next = dequeueNextReadyContext(
                    from: &readyContexts,
                    joinWaiters: joinWaiters
                )
                state = next.state
                activeThreadHandle = next.threadHandle
                contextSwitchCount += 1
            } else {
                return .halted("guest exit(\(exitCode))")
            }
        default:
            state.writeRegister("rax", value: 0)
        }
        return nil
    }

    private func allocateGuestMemory(
        size requestedSize: UInt64,
        alignment requestedAlignment: UInt64,
        heapCursor: inout UInt64,
        allocations: inout [UInt64: UInt64]
    ) -> UInt64 {
        let size = max(requestedSize, 1)
        let alignment = max(powerOfTwoAlignment(requestedAlignment), 16)
        let aligned = (heapCursor &+ alignment &- 1) & ~(alignment &- 1)
        let end = aligned &+ size
        guard end >= aligned, end <= Self.heapBase &+ Self.heapSize else { return 0 }
        heapCursor = (end &+ 15) & ~UInt64(15)
        allocations[aligned] = size
        return aligned
    }

    private func powerOfTwoAlignment(_ value: UInt64) -> UInt64 {
        guard value > 1 else { return 1 }
        var power: UInt64 = 1
        while power < value, power <= UInt64.max / 2 { power <<= 1 }
        return power
    }

    private func guestStringLength(at address: UInt64, memory: SparseVirtualMemory) throws -> UInt64 {
        guard address != 0 else { return 0 }
        var length: UInt64 = 0
        while length < 1_048_576 {
            if try memory.read(at: address &+ length, length: 1)[0] == 0 { return length }
            length += 1
        }
        return length
    }

    private func guestString(at address: UInt64, memory: SparseVirtualMemory) throws -> String {
        guard address != 0 else { return "" }
        let length = min(try guestStringLength(at: address, memory: memory), 16 * 1_024)
        guard length <= UInt64(Int.max) else { return "" }
        return String(decoding: try memory.read(at: address, length: Int(length)), as: UTF8.self)
    }

    private func parseGuestDouble(
        at address: UInt64,
        memory: SparseVirtualMemory
    ) throws -> (value: Double, endAddress: UInt64, rangeError: Bool) {
        guard address != 0 else { return (0, 0, false) }
        func byte(at offset: UInt64) throws -> UInt8 {
            try memory.read(at: address + offset, length: 1)[0]
        }
        func isDigit(_ value: UInt8) -> Bool { value >= 48 && value <= 57 }

        var offset: UInt64 = 0
        while offset < 4_096, [9, 10, 11, 12, 13, 32].contains(try byte(at: offset)) {
            offset += 1
        }
        let conversionStart = offset
        let sign = try byte(at: offset)
        if sign == 43 || sign == 45 { offset += 1 }

        var digitCount = 0
        while offset < 4_096, isDigit(try byte(at: offset)) {
            digitCount += 1
            offset += 1
        }
        if try byte(at: offset) == 46 {
            offset += 1
            while offset < 4_096, isDigit(try byte(at: offset)) {
                digitCount += 1
                offset += 1
            }
        }
        guard digitCount > 0 else { return (0, address, false) }

        let exponentStart = offset
        let exponentMarker = try byte(at: offset)
        if exponentMarker == 69 || exponentMarker == 101 {
            offset += 1
            let exponentSign = try byte(at: offset)
            if exponentSign == 43 || exponentSign == 45 { offset += 1 }
            let exponentDigitsStart = offset
            while offset < 4_096, isDigit(try byte(at: offset)) { offset += 1 }
            if exponentDigitsStart == offset { offset = exponentStart }
        }

        let length = offset - conversionStart
        guard length <= UInt64(Int.max) else { return (0, address, false) }
        let text = String(decoding: try memory.read(
            at: address + conversionStart,
            length: Int(length)
        ), as: UTF8.self)
        guard let value = Double(text) else { return (0, address, false) }
        return (value, address + offset, !value.isFinite)
    }

    private func parseGuestInteger(
        at address: UInt64,
        requestedBase: UInt64,
        signed: Bool,
        memory: SparseVirtualMemory
    ) throws -> (value: UInt64, endAddress: UInt64, overflow: Bool) {
        guard address != 0 else { return (0, 0, false) }
        func byte(at offset: UInt64) throws -> UInt8 {
            try memory.read(at: address + offset, length: 1)[0]
        }
        func digitValue(_ byte: UInt8) -> Int? {
            switch byte {
            case 48...57: Int(byte - 48)
            case 65...90: Int(byte - 65) + 10
            case 97...122: Int(byte - 97) + 10
            default: nil
            }
        }

        var offset: UInt64 = 0
        while offset < 4_096, [9, 10, 11, 12, 13, 32].contains(try byte(at: offset)) {
            offset += 1
        }
        var negative = false
        let signByte = try byte(at: offset)
        if signByte == 43 || signByte == 45 {
            negative = signByte == 45
            offset += 1
        }

        var base = Int(requestedBase)
        if base == 0 {
            if try byte(at: offset) == 48 {
                let prefix = try byte(at: offset + 1)
                if prefix == 120 || prefix == 88 {
                    base = 16
                    offset += 2
                } else {
                    base = 8
                }
            } else {
                base = 10
            }
        } else if base == 16,
                  try byte(at: offset) == 48,
                  [120, 88].contains(try byte(at: offset + 1)) {
            offset += 2
        }
        guard (2...36).contains(base) else { return (0, address, false) }

        let digitsStart = offset
        var magnitude: UInt64 = 0
        var overflow = false
        while offset < 4_096,
              let digit = digitValue(try byte(at: offset)),
              digit < base {
            let (multiplied, multiplyOverflow) = magnitude.multipliedReportingOverflow(by: UInt64(base))
            let (added, addOverflow) = multiplied.addingReportingOverflow(UInt64(digit))
            if multiplyOverflow || addOverflow {
                overflow = true
                magnitude = UInt64.max
            } else if !overflow {
                magnitude = added
            }
            offset += 1
        }
        guard offset > digitsStart else { return (0, address, false) }

        let value: UInt64
        if signed {
            let negativeLimit = UInt64(Int64.max) + 1
            if negative {
                if magnitude > negativeLimit {
                    overflow = true
                    value = UInt64(bitPattern: Int64.min)
                } else {
                    value = 0 &- magnitude
                }
            } else if magnitude > UInt64(Int64.max) {
                overflow = true
                value = UInt64(Int64.max)
            } else {
                value = magnitude
            }
        } else {
            value = negative ? 0 &- magnitude : magnitude
        }
        return (value, address + offset, overflow)
    }

    private func formatGuestVariadicString(
        _ format: String,
        vaListAddress: UInt64,
        memory: SparseVirtualMemory
    ) throws -> String {
        guard vaListAddress != 0 else { return format }
        var gpOffset = Int(try readInteger(size: 4, from: vaListAddress, memory: memory))
        var overflowArea = try readInteger(size: 8, from: vaListAddress + 8, memory: memory)
        let registerSaveArea = try readInteger(size: 8, from: vaListAddress + 16, memory: memory)

        func nextIntegerArgument() throws -> UInt64 {
            if gpOffset <= 40, registerSaveArea != 0 {
                let value = try readInteger(
                    size: 8,
                    from: registerSaveArea + UInt64(gpOffset),
                    memory: memory
                )
                gpOffset += 8
                return value
            }
            guard overflowArea != 0 else { return 0 }
            let value = try readInteger(size: 8, from: overflowArea, memory: memory)
            overflowArea += 8
            return value
        }

        return try renderGuestFormat(
            format,
            memory: memory,
            nextIntegerArgument: nextIntegerArgument
        )
    }

    private func formatGuestRegisterVariadicString(
        _ format: String,
        registerArguments: [UInt64],
        stackAddress: UInt64,
        memory: SparseVirtualMemory
    ) throws -> String {
        var argumentIndex = 0
        var stackCursor = stackAddress
        func nextIntegerArgument() throws -> UInt64 {
            if argumentIndex < registerArguments.count {
                let value = registerArguments[argumentIndex]
                argumentIndex += 1
                return value
            }
            let value = try readInteger(size: 8, from: stackCursor, memory: memory)
            stackCursor += 8
            return value
        }
        return try renderGuestFormat(
            format,
            memory: memory,
            nextIntegerArgument: nextIntegerArgument
        )
    }

    private func renderGuestFormat(
        _ format: String,
        memory: SparseVirtualMemory,
        nextIntegerArgument: () throws -> UInt64
    ) throws -> String {
        let bytes = Array(format.utf8)
        var output = ""
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x25 else {
                output.append(Character(UnicodeScalar(bytes[index])))
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            if bytes[index] == 0x25 {
                output.append("%")
                index += 1
                continue
            }

            while index < bytes.count, "-+ #0".utf8.contains(bytes[index]) { index += 1 }
            if index < bytes.count, bytes[index] == 0x2A {
                _ = try nextIntegerArgument()
                index += 1
            } else {
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
            }

            var precision: Int?
            if index < bytes.count, bytes[index] == 0x2E {
                index += 1
                if index < bytes.count, bytes[index] == 0x2A {
                    precision = Int(truncatingIfNeeded: try nextIntegerArgument())
                    index += 1
                } else {
                    var value = 0
                    while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                        value = value * 10 + Int(bytes[index] - 48)
                        index += 1
                    }
                    precision = value
                }
            }

            var longInteger = false
            if index < bytes.count, bytes[index] == 0x6C {
                longInteger = true
                index += 1
                if index < bytes.count, bytes[index] == 0x6C { index += 1 }
            } else if index < bytes.count, "jzt".utf8.contains(bytes[index]) {
                longInteger = true
                index += 1
            } else if index < bytes.count, bytes[index] == 0x68 {
                index += 1
                if index < bytes.count, bytes[index] == 0x68 { index += 1 }
            }

            guard index < bytes.count else { break }
            let specifier = bytes[index]
            index += 1
            switch specifier {
            case 0x73: // s
                let pointer = try nextIntegerArgument()
                var string = pointer == 0 ? "(null)" : try guestString(at: pointer, memory: memory)
                if let precision, precision >= 0, string.utf8.count > precision {
                    string = String(decoding: string.utf8.prefix(precision), as: UTF8.self)
                }
                output += string
            case 0x64, 0x69: // d, i
                let raw = try nextIntegerArgument()
                let value = longInteger
                    ? Int64(bitPattern: raw)
                    : Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
                output += String(value)
            case 0x75: // u
                let raw = try nextIntegerArgument()
                output += String(longInteger ? raw : UInt64(UInt32(truncatingIfNeeded: raw)))
            case 0x78, 0x58: // x, X
                let raw = try nextIntegerArgument()
                let value = longInteger ? raw : UInt64(UInt32(truncatingIfNeeded: raw))
                let string = String(value, radix: 16)
                output += specifier == 0x58 ? string.uppercased() : string
            case 0x70: // p
                output += "0x" + String(try nextIntegerArgument(), radix: 16)
            case 0x63: // c
                output.append(Character(UnicodeScalar(UInt8(truncatingIfNeeded: try nextIntegerArgument()))))
            default:
                output.append("%")
                output.append(Character(UnicodeScalar(specifier)))
            }
        }
        return output
    }

    private func resolveGuestFileURL(_ guestPath: String) -> URL? {
        guard let gameRootURL, !guestPath.isEmpty else { return nil }
        var relative = guestPath.replacingOccurrences(of: "\\", with: "/")
        if relative.hasPrefix("app0:/") {
            relative.removeFirst("app0:/".count)
        } else if let appRoot = relative.range(of: "/app0/") {
            relative = String(relative[appRoot.upperBound...])
        }
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        while relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.isEmpty else { return nil }

        let candidate = gameRootURL.appendingPathComponent(relative).standardizedFileURL
        let rootPath = gameRootURL.path.hasSuffix("/") ? gameRootURL.path : gameRootURL.path + "/"
        guard candidate.path == gameRootURL.path || candidate.path.hasPrefix(rootPath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }

    /// Dreaming Sarah's Construct project is a single 1.2 MB JSON document.
    /// For the menu milestone, keep the complete type/media tables but retain
    /// only the initial Launcher layouts and the transitive event sheets they
    /// name. This transformation is in-memory; the title's data.js is read-only.
    private func makeDreamingSarahMenuBootPayload(
        from data: Data
    ) -> (data: Data, jsonSize: Int)? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var project = root["project"] as? [Any],
              project.count > 6,
              let initialLayout = project[1] as? String,
              initialLayout == "Launcher",
              let layouts = project[5] as? [[Any]],
              let eventSheets = project[6] as? [[Any]] else { return nil }

        let eventSheetNames = Set(eventSheets.compactMap { $0.first as? String })
        var retainedEventSheetNames: Set<String> = [initialLayout]
        var changed = true
        while changed {
            changed = false
            for sheet in eventSheets {
                guard let name = sheet.first as? String,
                      retainedEventSheetNames.contains(name) else { continue }
                var values: [Any] = [sheet]
                while let value = values.popLast() {
                    if let array = value as? [Any] {
                        values.append(contentsOf: array)
                    } else if let dictionary = value as? [String: Any] {
                        values.append(contentsOf: dictionary.values)
                    } else if let string = value as? String,
                              eventSheetNames.contains(string),
                              retainedEventSheetNames.insert(string).inserted {
                        changed = true
                    }
                }
            }
        }

        let retainedLayouts: Set<String> = [initialLayout, "Launcherbtset", "fader"]
        project[5] = layouts.filter {
            guard let name = $0.first as? String else { return false }
            return retainedLayouts.contains(name)
        }
        project[6] = eventSheets.filter {
            guard let name = $0.first as? String else { return false }
            return retainedEventSheetNames.contains(name)
        }
        root["project"] = project
        guard let json = try? JSONSerialization.data(withJSONObject: root) else { return nil }
        var output = Data([0xEF, 0xBB, 0xBF])
        let jsonSize = output.count + json.count
        guard jsonSize < data.count else { return nil }
        output.append(json)
        output.append(Data(repeating: 0x20, count: data.count - jsonSize))
        return (output, jsonSize)
    }

    private func writeInteger(
        _ value: UInt64,
        size: Int,
        to address: UInt64,
        memory: inout SparseVirtualMemory
    ) throws {
        guard (1...8).contains(size) else { throw ARMInterpreterError.unsupportedWidth(size) }
        var bytes = Data(count: size)
        for index in 0..<size {
            bytes[index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
        }
        try memory.write(bytes, at: address)
    }

    private func push(_ value: UInt64, state: inout X86CPUState, memory: inout SparseVirtualMemory) throws {
        let stackPointer = state.readRegister("rsp") &- 8
        state.writeRegister("rsp", value: stackPointer)
        try writeInteger(value, size: 8, to: stackPointer, memory: &memory)
    }

    private func pop(state: inout X86CPUState, memory: SparseVirtualMemory) throws -> UInt64 {
        let stackPointer = state.readRegister("rsp")
        let value = try readInteger(size: 8, from: stackPointer, memory: memory)
        state.writeRegister("rsp", value: stackPointer &+ 8)
        return value
    }

    private func requireOperands(
        _ operands: [X86Operand],
        count: Int,
        instruction: X86Instruction
    ) throws {
        guard operands.count == count else {
            throw ARMInterpreterError.invalidOperand(instruction.text)
        }
    }

    private func mask(forByteCount byteCount: Int) -> UInt64 {
        byteCount >= 8 ? UInt64.max : (UInt64(1) << UInt64(byteCount * 8)) - 1
    }

    private func signBit(forByteCount byteCount: Int) -> UInt64 {
        UInt64(1) << UInt64(byteCount * 8 - 1)
    }

    private func signExtend(_ value: UInt64, fromByteCount byteCount: Int) -> UInt64 {
        guard byteCount > 0, byteCount < 8 else { return value }
        let valueMask = mask(forByteCount: byteCount)
        let masked = value & valueMask
        return masked & signBit(forByteCount: byteCount) == 0 ? masked : masked | ~valueMask
    }

    private func reverseBytes(_ value: UInt64, size: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<size {
            result |= ((value >> UInt64(index * 8)) & 0xFF) << UInt64((size - index - 1) * 8)
        }
        return result
    }
}

private enum X86Flag: UInt64 {
    case carry = 0x001
    case parity = 0x004
    case auxiliary = 0x010
    case zero = 0x040
    case sign = 0x080
    case direction = 0x400
    case overflow = 0x800
}

private struct X86RegisterDescriptor {
    let base: String
    let width: Int
    let bitOffset: Int
    let zeroExtends: Bool
}

private struct RunnableGuestContext {
    let state: X86CPUState
    let threadHandle: UInt64
}

private struct SleepingGuestContext {
    let context: RunnableGuestContext
    let wakeInstruction: Int
    let mutexToReacquire: UInt64?
    let mutexDepth: Int
}

private struct GuestMutexState {
    let owner: UInt64
    var depth: Int
}

private struct GuestMutexWaiter {
    let context: RunnableGuestContext
    let depth: Int
}

private struct AGCCommandBufferSummary {
    let packetCount: Int
    let flipPacketCount: Int
    let signatureText: String
    let stateText: String
}

private struct AGCRegisterDefaultValue: Sendable {
    let offset: UInt64
    let value: UInt64

    init(_ offset: UInt64, _ value: UInt64) {
        self.offset = offset
        self.value = value
    }
}

private struct AGCRegisterDefaultGroup: Sendable {
    let space: UInt64
    let index: UInt64
    let type: UInt64
    let registers: [AGCRegisterDefaultValue]

    init(
        _ space: UInt64,
        _ index: UInt64,
        _ type: UInt64,
        _ registers: [AGCRegisterDefaultValue]
    ) {
        self.space = space
        self.index = index
        self.type = type
        self.registers = registers
    }
}

private let agcPrimaryRegisterDefaults: [AGCRegisterDefaultGroup] = [
    .init(0, 0, 0xE24F806D, [.init(0x202, 0x00CC0010)]),
    .init(0, 3, 0x0BC65DA4, [.init(0x08F, 0)]),
    .init(0, 4, 0x9E5AD592, [.init(0x08E, 0)]),
    .init(0, 12, 0x6DE4C312, [.init(0x203, 0)]),
    .init(0, 28, 0x1EB8D73A, [.init(0x292, 0x00000002)]),
    .init(0, 31, 0xA20EFC70, [.init(0x080, 0)]),
    .init(0, 58, 0x43FBD769, [
        .init(0x105, 0), .init(0x107, 0), .init(0x106, 0), .init(0x108, 0)
    ]),
    .init(0, 59, 0xEF550356, [.init(0x1E0, 0x20010001)]),
    .init(0, 67, 0x918106BB, [.init(0x090, 0x80000000), .init(0x091, 0x40004000)]),
    .init(0, 72, 0x38E92C91, [
        .init(0x318, 0), .init(0x31B, 0), .init(0x31C, 0), .init(0x31D, 0),
        .init(0x31E, 0x48), .init(0x31F, 0), .init(0x321, 0), .init(0x323, 0),
        .init(0x324, 0), .init(0x325, 0), .init(0x390, 0), .init(0x398, 0),
        .init(0x3A0, 0), .init(0x3A8, 0), .init(0x3B0, 0), .init(0x3B8, 0x0006C000)
    ]),
    .init(0, 73, 0x0B177B43, [.init(0x00C, 0), .init(0x00D, 0x40004000)]),
    .init(0, 74, 0x48531062, [.init(0x191, 0)]),
    .init(0, 76, 0x7690AF6F, [
        .init(0x10F, 0x4E7E0000), .init(0x111, 0x4E7E0000),
        .init(0x113, 0x4E7E0000), .init(0x110, 0), .init(0x112, 0),
        .init(0x114, 0), .init(0x094, 0x80000000), .init(0x095, 0x40004000),
        .init(0x0B4, 0), .init(0x0B5, 0)
    ]),
    .init(0, 77, 0x078D7060, [.init(0x081, 0x80000000), .init(0x082, 0x40004000)]),
    .init(1, 13, 0xC918DF3E, [.init(0x20C, 0), .init(0x20D, 0)]),
    .init(1, 14, 0xC9751C9C, [.init(0x0C8, 0), .init(0x0C9, 0)]),
    .init(1, 18, 0xC9E01B31, [.init(0x008, 0), .init(0x009, 0)]),
    .init(2, 3, 0x105971C2, [.init(0x25B, 0)]),
    .init(2, 7, 0x40D49AD1, [.init(0x262, 0)]),
    .init(2, 12, 0x9EBFAB10, [.init(0x242, 0)])
]

private let agcInternalRegisterDefaults: [AGCRegisterDefaultGroup] = [
    .init(0, 0, 0x8FB4EDB5, [.init(0x00E, 0)]),
    .init(0, 1, 0xB994AD29, [.init(0x2AF, 0)]),
    .init(0, 2, 0xD427322F, [.init(0x314, 0)]),
    .init(0, 3, 0xF58FEA31, [.init(0x1B5, 0)]),
    .init(1, 0, 0x6AC156EF, [.init(0x216, 0)]),
    .init(1, 1, 0x6AC15610, [.init(0x217, 0)]),
    .init(1, 2, 0x6AC15009, [.init(0x219, 0)]),
    .init(1, 3, 0x6AC153BA, [.init(0x21A, 0)]),
    .init(1, 4, 0xBE7DCD73, [.init(0x27D, 0)]),
    .init(1, 5, 0x0C4B1438, [.init(0x22A, 0)]),
    .init(1, 6, 0xDB00D71A, [.init(0x204, 0)]),
    .init(1, 7, 0xDB00D249, [.init(0x205, 0)]),
    .init(1, 8, 0xDB00EC60, [.init(0x206, 0)]),
    .init(1, 9, 0x0C4D6FE4, [.init(0x080, 0)]),
    .init(1, 10, 0x0C4A80EF, [.init(0x100, 0)]),
    .init(1, 11, 0x0DD283E7, [.init(0x006, 0)]),
    .init(1, 12, 0xC620E68C, [.init(0x081, 0)]),
    .init(1, 13, 0xC67EFACF, [.init(0x101, 0)]),
    .init(1, 14, 0xD9E6D9F7, [.init(0x001, 0)]),
    .init(2, 0, 0x31F34B9F, [.init(0x24F, 0)]),
    .init(2, 1, 0xAC0F9E76, [.init(0x80003FFF, 0)]),
    .init(2, 2, 0x929FD95D, [.init(0x250, 0)])
]

private struct GuestJoinWaiter {
    let context: RunnableGuestContext
    let resultAddress: UInt64
}

private struct GuestOpenFile {
    let data: Data
    var offset: Int
}

private struct X86CPUState {
    var rip: UInt64
    var flags: UInt64 = 0x202
    var fsBase: UInt64 = 0
    var gsBase: UInt64 = 0
    private var registers: [String: UInt64] = [:]
    private var vectorRegisters: [Int: Data] = [:]

    init(rip: UInt64) {
        self.rip = rip
        for name in [
            "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
            "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"
        ] {
            registers[name] = 0
        }
    }

    func readRegister(_ name: String) -> UInt64 {
        (try? checkedReadRegister(name)) ?? 0
    }

    mutating func writeRegister(_ name: String, value: UInt64) {
        try? checkedWriteRegister(name, value: value)
    }

    func checkedReadRegister(_ name: String) throws -> UInt64 {
        if name == "rip" { return rip }
        if name == "eflags" || name == "rflags" { return flags }
        guard let descriptor = Self.descriptor(for: name), let full = registers[descriptor.base] else {
            throw ARMInterpreterError.unknownRegister(name)
        }
        let mask = descriptor.width == 8
            ? UInt64.max
            : (UInt64(1) << UInt64(descriptor.width * 8)) - 1
        return (full >> UInt64(descriptor.bitOffset)) & mask
    }

    mutating func checkedWriteRegister(_ name: String, value: UInt64) throws {
        if name == "rip" { rip = value; return }
        if name == "eflags" || name == "rflags" { flags = value; return }
        guard let descriptor = Self.descriptor(for: name), let old = registers[descriptor.base] else {
            throw ARMInterpreterError.unknownRegister(name)
        }
        let valueMask = descriptor.width == 8
            ? UInt64.max
            : (UInt64(1) << UInt64(descriptor.width * 8)) - 1
        if descriptor.zeroExtends {
            registers[descriptor.base] = value & valueMask
        } else if descriptor.width == 8 {
            registers[descriptor.base] = value
        } else {
            let shiftedMask = valueMask << UInt64(descriptor.bitOffset)
            registers[descriptor.base] = (old & ~shiftedMask)
                | ((value & valueMask) << UInt64(descriptor.bitOffset))
        }
    }

    static func isVectorRegister(_ name: String) -> Bool {
        vectorDescriptor(for: name) != nil
    }

    func readVectorRegister(_ name: String, byteCount: Int) throws -> Data {
        guard let (index, maximumWidth) = Self.vectorDescriptor(for: name), byteCount <= maximumWidth else {
            throw ARMInterpreterError.unknownRegister(name)
        }
        let stored = vectorRegisters[index] ?? Data(repeating: 0, count: 64)
        return Data(stored.prefix(byteCount))
    }

    mutating func writeVectorRegister(_ name: String, bytes: Data, byteCount: Int) throws {
        guard let (index, maximumWidth) = Self.vectorDescriptor(for: name), byteCount <= maximumWidth else {
            throw ARMInterpreterError.unknownRegister(name)
        }
        var stored = vectorRegisters[index] ?? Data(repeating: 0, count: 64)
        let writeCount = min(byteCount, bytes.count)
        if writeCount > 0 {
            stored.replaceSubrange(0..<writeCount, with: bytes.prefix(writeCount))
        }
        if writeCount < byteCount {
            stored.replaceSubrange(writeCount..<byteCount, with: repeatElement(UInt8(0), count: byteCount - writeCount))
        }
        if name.hasPrefix("xmm"), byteCount <= 16 {
            stored.replaceSubrange(16..<64, with: repeatElement(UInt8(0), count: 48))
        }
        vectorRegisters[index] = stored
    }

    func flag(_ flag: X86Flag) -> Bool {
        flags & flag.rawValue != 0
    }

    mutating func setFlag(_ flag: X86Flag, _ enabled: Bool) {
        if enabled { flags |= flag.rawValue } else { flags &= ~flag.rawValue }
    }

    mutating func updateLogicFlags(result: UInt64, byteCount: Int) {
        setFlag(.carry, false)
        setFlag(.overflow, false)
        updateZeroSignParity(result: result, byteCount: byteCount)
    }

    mutating func updateZeroSignParity(result: UInt64, byteCount: Int) {
        let mask = byteCount >= 8 ? UInt64.max : (UInt64(1) << UInt64(byteCount * 8)) - 1
        let value = result & mask
        setFlag(.zero, value == 0)
        setFlag(.sign, value & (UInt64(1) << UInt64(byteCount * 8 - 1)) != 0)
        setFlag(.parity, (UInt8(truncatingIfNeeded: value).nonzeroBitCount & 1) == 0)
    }

    mutating func updateAddFlags(lhs: UInt64, rhs: UInt64, result: UInt64, byteCount: Int) {
        let mask = byteCount >= 8 ? UInt64.max : (UInt64(1) << UInt64(byteCount * 8)) - 1
        let left = lhs & mask
        let right = rhs & mask
        let value = result & mask
        let sign = UInt64(1) << UInt64(byteCount * 8 - 1)
        setFlag(.carry, value < left)
        setFlag(.overflow, ((~(left ^ right) & (left ^ value)) & sign) != 0)
        setFlag(.auxiliary, ((left ^ right ^ value) & 0x10) != 0)
        updateZeroSignParity(result: value, byteCount: byteCount)
    }

    mutating func updateSubtractFlags(lhs: UInt64, rhs: UInt64, result: UInt64, byteCount: Int) {
        let mask = byteCount >= 8 ? UInt64.max : (UInt64(1) << UInt64(byteCount * 8)) - 1
        let left = lhs & mask
        let right = rhs & mask
        let value = result & mask
        let sign = UInt64(1) << UInt64(byteCount * 8 - 1)
        setFlag(.carry, left < right)
        setFlag(.overflow, (((left ^ right) & (left ^ value)) & sign) != 0)
        setFlag(.auxiliary, ((left ^ right ^ value) & 0x10) != 0)
        updateZeroSignParity(result: value, byteCount: byteCount)
    }

    private static func descriptor(for name: String) -> X86RegisterDescriptor? {
        if ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp"].contains(name) {
            return X86RegisterDescriptor(base: name, width: 8, bitOffset: 0, zeroExtends: false)
        }
        if name.count >= 2, name.first == "r", let number = Int(name.dropFirst()), (8...15).contains(number) {
            return X86RegisterDescriptor(base: "r\(number)", width: 8, bitOffset: 0, zeroExtends: false)
        }

        let legacy: [String: X86RegisterDescriptor] = [
            "eax": .init(base: "rax", width: 4, bitOffset: 0, zeroExtends: true),
            "ax": .init(base: "rax", width: 2, bitOffset: 0, zeroExtends: false),
            "al": .init(base: "rax", width: 1, bitOffset: 0, zeroExtends: false),
            "ah": .init(base: "rax", width: 1, bitOffset: 8, zeroExtends: false),
            "ebx": .init(base: "rbx", width: 4, bitOffset: 0, zeroExtends: true),
            "bx": .init(base: "rbx", width: 2, bitOffset: 0, zeroExtends: false),
            "bl": .init(base: "rbx", width: 1, bitOffset: 0, zeroExtends: false),
            "bh": .init(base: "rbx", width: 1, bitOffset: 8, zeroExtends: false),
            "ecx": .init(base: "rcx", width: 4, bitOffset: 0, zeroExtends: true),
            "cx": .init(base: "rcx", width: 2, bitOffset: 0, zeroExtends: false),
            "cl": .init(base: "rcx", width: 1, bitOffset: 0, zeroExtends: false),
            "ch": .init(base: "rcx", width: 1, bitOffset: 8, zeroExtends: false),
            "edx": .init(base: "rdx", width: 4, bitOffset: 0, zeroExtends: true),
            "dx": .init(base: "rdx", width: 2, bitOffset: 0, zeroExtends: false),
            "dl": .init(base: "rdx", width: 1, bitOffset: 0, zeroExtends: false),
            "dh": .init(base: "rdx", width: 1, bitOffset: 8, zeroExtends: false),
            "esi": .init(base: "rsi", width: 4, bitOffset: 0, zeroExtends: true),
            "si": .init(base: "rsi", width: 2, bitOffset: 0, zeroExtends: false),
            "sil": .init(base: "rsi", width: 1, bitOffset: 0, zeroExtends: false),
            "edi": .init(base: "rdi", width: 4, bitOffset: 0, zeroExtends: true),
            "di": .init(base: "rdi", width: 2, bitOffset: 0, zeroExtends: false),
            "dil": .init(base: "rdi", width: 1, bitOffset: 0, zeroExtends: false),
            "ebp": .init(base: "rbp", width: 4, bitOffset: 0, zeroExtends: true),
            "bp": .init(base: "rbp", width: 2, bitOffset: 0, zeroExtends: false),
            "bpl": .init(base: "rbp", width: 1, bitOffset: 0, zeroExtends: false),
            "esp": .init(base: "rsp", width: 4, bitOffset: 0, zeroExtends: true),
            "sp": .init(base: "rsp", width: 2, bitOffset: 0, zeroExtends: false),
            "spl": .init(base: "rsp", width: 1, bitOffset: 0, zeroExtends: false)
        ]
        if let descriptor = legacy[name] { return descriptor }

        for number in 8...15 {
            let base = "r\(number)"
            if name == "r\(number)d" { return .init(base: base, width: 4, bitOffset: 0, zeroExtends: true) }
            if name == "r\(number)w" { return .init(base: base, width: 2, bitOffset: 0, zeroExtends: false) }
            if name == "r\(number)b" { return .init(base: base, width: 1, bitOffset: 0, zeroExtends: false) }
        }
        return nil
    }

    private static func vectorDescriptor(for name: String) -> (Int, Int)? {
        let width: Int
        let suffix: Substring
        if name.hasPrefix("xmm") {
            width = 16
            suffix = name.dropFirst(3)
        } else if name.hasPrefix("ymm") {
            width = 32
            suffix = name.dropFirst(3)
        } else if name.hasPrefix("zmm") {
            width = 64
            suffix = name.dropFirst(3)
        } else {
            return nil
        }
        guard let index = Int(suffix), (0...31).contains(index) else { return nil }
        return (index, width)
    }
}
