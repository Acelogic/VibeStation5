// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

actor PS5RuntimeEngine {
    private var preparedImage: ExecutableLoadReport?
    private var preparedGameRoot: URL?

    func prepare(game: Game, folder: ImportedFolder, mode: BootMode) throws -> RuntimePreparation {
        let root = try FolderBookmarkStore.resolve(folder)
        let scoped = root.startAccessingSecurityScopedResource()
        defer {
            if scoped { root.stopAccessingSecurityScopedResource() }
        }

        let executable = root.appendingPathComponent(game.executableRelativePath, isDirectory: false)
        let data = try Data(contentsOf: executable, options: [.mappedIfSafe])
        let image = try ExecutableParser().parse(data)

        if mode == .systemUI, image.format == .ps4SELF {
            throw BinaryFormatError.unsupported("System UI mode expects a PS5 SELF or decrypted PS5 ELF image.")
        }

        let report = try ExecutableLoader().load(data, image: image)
        preparedImage = report
        preparedGameRoot = executable.deletingLastPathComponent()

        return RuntimePreparation(
            format: image.format,
            entryPoint: report.entryPoint,
            programHeaderCount: image.programHeaders.count,
            loadableSegmentCount: image.loadableSegments.count,
            reservedMemoryBytes: report.memory.reservedByteCount,
            loadedMemoryBytes: report.loadedBytes,
            encryptedSegmentCount: image.selfSegments.filter(\.isEncrypted).count,
            compressedSegmentCount: image.selfSegments.filter(\.isCompressed).count,
            appliedRelocationCount: report.appliedRelocationCount,
            importSymbolCount: report.importSymbolsByIndex.count,
            cpuBackend: "ARM-native Swift x86-64 interpreter"
        )
    }

    func start(
        instructionBudget: Int = 500_000_000,
        videoFrameHandler: (@Sendable (GuestVideoFrame) -> Void)? = nil,
        audioBufferHandler: (@Sendable (GuestAudioBuffer) -> Void)? = nil,
        inputStateProvider: (@Sendable () -> GuestInputState)? = nil,
        runtimeEventHandler: (@Sendable (String) -> Void)? = nil
    ) throws -> ARMExecutionReport {
        guard let preparedImage else {
            throw BinaryFormatError.invalid("Prepare an executable image before starting the guest CPU.")
        }
        let scoped = preparedGameRoot?.startAccessingSecurityScopedResource() ?? false
        defer {
            if scoped { preparedGameRoot?.stopAccessingSecurityScopedResource() }
        }
        var memory = preparedImage.memory
        return try ARMNativeX86Interpreter(
            gameRootURL: preparedGameRoot,
            videoFrameHandler: videoFrameHandler,
            audioBufferHandler: audioBufferHandler,
            inputStateProvider: inputStateProvider,
            runtimeEventHandler: runtimeEventHandler
        ).run(
            memory: &memory,
            entryPoint: preparedImage.entryPoint,
            importSymbolsByIndex: preparedImage.importSymbolsByIndex,
            instructionBudget: instructionBudget
        )
    }

    func clear() {
        preparedImage = nil
        preparedGameRoot = nil
    }
}
