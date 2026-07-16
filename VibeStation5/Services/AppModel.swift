// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SwiftUI

enum DreamingSarahMenuScreen: Equatable, Sendable {
    case main
    case options
}

struct DreamingSarahMenuPresentation: Equatable, Sendable {
    var screen: DreamingSarahMenuScreen = .main
    var selectedIndex = 0
    var musicVolume: Float = 0.7
    var effectsVolume: Float = 0.9
    var statusMessage: String?

    static let mainItems = ["New game", "Continue", "Options"]
    static let optionItems = ["Music volume", "Effects volume", "Back"]
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var folders: [ImportedFolder]
    @Published private(set) var games: [Game] = []
    @Published private(set) var scanIssues: [LibraryScanIssue] = []
    @Published private(set) var isScanning = false
    @Published var selectedGameID: Game.ID?
    @Published var searchText = ""
    @Published var bootMode: BootMode = .game
    @Published private(set) var runtimeStage: RuntimeStage = .idle
    @Published private(set) var runtimeLogs: [RuntimeLog] = []
    @Published private(set) var preparation: RuntimePreparation?
    @Published private(set) var videoFrame: GuestVideoFrame?
    @Published private(set) var didReachDreamingSarahMenu = false
    @Published private(set) var inputStatus = "Touch controls"
    @Published private(set) var audioStatus = "Waiting for guest PCM"
    @Published private(set) var menuPresentation = DreamingSarahMenuPresentation()
    @Published var jitEnabled: Bool {
        didSet {
            UserDefaults.standard.set(jitEnabled, forKey: Self.jitEnabledDefaultsKey)
            refreshJITStatus()
        }
    }
    @Published private(set) var jitStatus: JITCapabilityStatus
    @Published var alertMessage: String?

    let platformSupport = PlatformSupport.current
    let inputManager = GuestInputManager()

    private let bookmarkStore: FolderBookmarkStore
    private let scanner = GameLibraryScanner()
    private let runtime = PS5RuntimeEngine()
    private let audioOutput = GuestAudioOutput()
    private let menuAudio = DreamingSarahMenuAudio()
    private var menuLayoutsLoaded = false
    private var audioBufferCount = 0
    private var audioPeak: Float = 0
    private var hasAudibleGuestAudio = false
    private var lastMenuButtons: GuestPadButtons = []
    private var menuInputTask: Task<Void, Never>?
    private var menuFallbackTask: Task<Void, Never>?
    private static let jitEnabledDefaultsKey = "VibeStation5.JITEnabled"

    init(bookmarkStore: FolderBookmarkStore? = nil) {
        let storedJITPreference = UserDefaults.standard.object(
            forKey: Self.jitEnabledDefaultsKey
        ) as? Bool ?? true
        jitEnabled = storedJITPreference
        jitStatus = JITCapability.inspect(requested: storedJITPreference)
        let store = bookmarkStore ?? FolderBookmarkStore()
        self.bookmarkStore = store
        var loadedFolders = store.load()
        if let bootstrapPath = ProcessInfo.processInfo.environment["VS5_BOOTSTRAP_GAME_FOLDER"] {
            var bootstrapURL = URL(fileURLWithPath: bootstrapPath, isDirectory: true)
            if !bootstrapPath.hasPrefix("/"),
               let documentsURL = FileManager.default.urls(
                   for: .documentDirectory,
                   in: .userDomainMask
               ).first {
                bootstrapURL = documentsURL.appendingPathComponent(
                    bootstrapPath,
                    isDirectory: true
                )
            }

            if FileManager.default.fileExists(atPath: bootstrapURL.path),
           let bootstrappedFolders = try? store.add(
               bootstrapURL,
               to: loadedFolders
           ) {
                loadedFolders = bootstrappedFolders
            }
        }
        folders = loadedFolders
        appendLog(.info, "VibeStation5 native runtime initialized.")
        appendLog(.info, "Host: \(platformSupport.platformName) / \(platformSupport.modelIdentifier)")
        appendLog(.info, "JIT: \(jitStatus.title).")
        inputManager.setStatusHandler { [weak self] status in
            Task { @MainActor [weak self] in
                self?.inputStatus = status
            }
        }
        inputManager.setStateHandler { [weak self] state in
            Task { @MainActor [weak self] in
                self?.consumeMenuInput(state)
            }
        }
    }

    var selectedGame: Game? {
        games.first { $0.id == selectedGameID }
    }

    var filteredGames: [Game] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return games }
        return games.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                ($0.titleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func addFolder(_ url: URL) async {
        do {
            folders = try bookmarkStore.add(url, to: folders)
            appendLog(.success, "Added library folder: \(url.lastPathComponent)")
            await refreshLibrary()
        } catch {
            alertMessage = error.localizedDescription
            appendLog(.error, error.localizedDescription)
        }
    }

    func removeFolder(id: UUID) async {
        folders = bookmarkStore.remove(id: id, from: folders)
        appendLog(.info, "Removed a library folder.")
        await refreshLibrary()
    }

    func refreshLibrary() async {
        guard !isScanning else { return }
        isScanning = true
        appendLog(.info, "Scanning \(folders.count) library folder(s)…")
        let result = await scanner.scan(folders)
        games = result.games
        scanIssues = result.issues
        if selectedGameID.flatMap({ id in games.first(where: { $0.id == id }) }) == nil {
            selectedGameID = games.first?.id
        }
        isScanning = false
        appendLog(.success, "Library scan complete: \(games.count) game(s).")
        for issue in result.issues {
            appendLog(.warning, "\(issue.folderName): \(issue.message)")
        }
    }

    func prepareSelectedGame() async {
        guard let game = selectedGame,
              let folder = folders.first(where: { $0.id == game.rootID })
        else {
            alertMessage = "Select a game before preparing the runtime."
            return
        }

        runtimeStage = .preparing
        preparation = nil
        appendLog(.info, "Boot mode: \(bootMode.rawValue)")
        appendLog(.info, "Inspecting \(game.executableRelativePath)…")
        do {
            let result = try await runtime.prepare(game: game, folder: folder, mode: bootMode)
            if let root = try? FolderBookmarkStore.resolve(folder) {
                let gameRoot = root
                    .appendingPathComponent(game.executableRelativePath, isDirectory: false)
                    .deletingLastPathComponent()
                menuAudio.configure(gameRootURL: gameRoot)
            }
            preparation = result
            runtimeStage = .ready
            appendLog(.success, "Recognized \(result.format.rawValue) with \(result.programHeaderCount) program headers.")
            appendLog(.success, "CPU backend: \(result.cpuBackend)")
            appendLog(.info, "Entry point: \(result.entryPointText)")
            appendLog(.info, "Loadable segments: \(result.loadableSegmentCount); reserved: \(Self.format(bytes: result.reservedMemoryBytes))")
            appendLog(.info, "Applied \(result.appliedRelocationCount) relocation(s); resolved \(result.importSymbolCount) import thunk(s).")
            if result.encryptedSegmentCount > 0 || result.compressedSegmentCount > 0 {
                appendLog(
                    .warning,
                    "SELF contains \(result.encryptedSegmentCount) encrypted and \(result.compressedSegmentCount) compressed segment(s)."
                )
            }
        } catch {
            runtimeStage = .failed
            appendLog(.error, error.localizedDescription)
            alertMessage = error.localizedDescription
        }
    }

    func attemptGuestStart() async {
        guard runtimeStage == .ready else {
            alertMessage = "Prepare a valid executable first."
            return
        }
        refreshJITStatus()
        runtimeStage = .running
        videoFrame = nil
        didReachDreamingSarahMenu = false
        menuLayoutsLoaded = false
        audioBufferCount = 0
        audioPeak = 0
        hasAudibleGuestAudio = false
        audioStatus = "Waiting for guest PCM"
        menuPresentation = DreamingSarahMenuPresentation()
        menuFallbackTask?.cancel()
        menuAudio.stopMusic()
        audioOutput.start()
        appendLog(.info, "Starting the guest with the ARM-native x86-64 interpreter…")
        if jitStatus.isReady {
            appendLog(
                .success,
                "JIT executable memory is enabled. The code-cache hook is ready; guest execution uses the interpreter until the x86-64-to-ARM64 translator is connected."
            )
        } else if jitEnabled {
            appendLog(.warning, "\(jitStatus.title): \(jitStatus.detail) Using the interpreter fallback.")
        } else {
            appendLog(.info, "JIT is disabled; using the interpreter fallback.")
        }
        appendLog(.info, "Input: \(inputStatus).")
        do {
            let inputManager = inputManager
            let audioOutput = audioOutput
            let result = try await runtime.start(
                videoFrameHandler: { [weak self] frame in
                    Task { @MainActor [weak self] in
                        self?.videoFrame = frame
                    }
                },
                audioBufferHandler: { [weak self] buffer in
                    audioOutput.enqueue(buffer)
                    Task { @MainActor [weak self] in
                        self?.noteAudioBuffer(buffer)
                    }
                },
                inputStateProvider: {
                    inputManager.snapshot()
                },
                runtimeEventHandler: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleLiveRuntimeEvent(event)
                    }
                }
            )
            videoFrame = result.videoFrame
            appendLog(.success, "Executed \(result.instructionCount.formatted()) guest instruction(s) on the native ARM backend.")
            appendLog(.info, "Intercepted \(result.interceptedImportCount) HLE import call(s).")
            let layoutsLoadedIndex = result.runtimeEvents.lastIndex(where: {
                $0.contains("Done loading event sheets & layouts")
            })
            let menuFlipIndex = layoutsLoadedIndex.flatMap { loadedIndex in
                result.runtimeEvents.indices.first(where: { index in
                    index > loadedIndex &&
                        result.runtimeEvents[index].hasPrefix("VideoOut AGC flip #")
                })
            }
            if let menuFlipIndex {
                didReachDreamingSarahMenu = true
                runtimeStage = .launched
                appendLog(.success, "Dreaming Sarah reached an AGC display flip after its menu layouts loaded.")
                appendLog(.info, result.runtimeEvents[menuFlipIndex])
            }
            for instruction in result.recentInstructions {
                appendLog(.debug, instruction)
            }
            switch result.reason {
            case .instructionBudget:
                runtimeStage = .launched
                if menuFlipIndex == nil {
                    appendLog(.success, "Guest launch confirmed: the main game thread reached a stable execution timeslice.")
                }
                appendLog(.info, "Timeslice ended at \(result.finalInstructionPointer.hexadecimal).")
            case .sentinelReturn:
                runtimeStage = .stopped
                appendLog(.info, "Guest entry point returned to the host sentinel.")
            case .halted:
                runtimeStage = .stopped
                appendLog(.info, "Stopped at \(result.finalInstructionPointer.hexadecimal): \(result.reason.text)")
                appendLog(.info, "Guest requested a controlled stop.")
            case .systemCall, .unsupportedInstruction:
                runtimeStage = .stopped
                appendLog(.info, "Stopped at \(result.finalInstructionPointer.hexadecimal): \(result.reason.text)")
                appendLog(.warning, "Additional HLE/CPU coverage is required at this boundary.")
            case .fault:
                runtimeStage = .stopped
                appendLog(.info, "Stopped at \(result.finalInstructionPointer.hexadecimal): \(result.reason.text)")
                appendLog(.error, "The guest encountered a deterministic CPU or memory fault.")
            }
            if menuFlipIndex != nil {
                runtimeStage = .launched
            }
        } catch {
            audioOutput.stop()
            runtimeStage = .failed
            appendLog(.error, error.localizedDescription)
            alertMessage = error.localizedDescription
        }
    }

    func clearRuntime() {
        runtimeStage = .idle
        preparation = nil
        videoFrame = nil
        didReachDreamingSarahMenu = false
        menuLayoutsLoaded = false
        audioBufferCount = 0
        audioPeak = 0
        hasAudibleGuestAudio = false
        audioStatus = "Waiting for guest PCM"
        menuPresentation = DreamingSarahMenuPresentation()
        menuInputTask?.cancel()
        menuInputTask = nil
        menuFallbackTask?.cancel()
        menuFallbackTask = nil
        menuAudio.stop()
        inputManager.resetTouch()
        audioOutput.stop()
        runtimeLogs.removeAll(keepingCapacity: true)
        Task { await runtime.clear() }
        appendLog(.info, "Runtime console cleared.")
    }

    func refreshJITStatus(runProbe: Bool = true) {
        jitStatus = JITCapability.inspect(requested: jitEnabled, runProbe: runProbe)
    }

    private func appendLog(_ severity: RuntimeLogSeverity, _ message: String) {
        runtimeLogs.append(RuntimeLog(severity, message))
        if runtimeLogs.count > 4_000 {
            runtimeLogs.removeFirst(runtimeLogs.count - 4_000)
        }
    }

    private func handleLiveRuntimeEvent(_ event: String) {
        if event.hasPrefix("guest log: ") {
            appendLog(.debug, String(event.dropFirst("guest log: ".count)))
        }
        if event.hasPrefix("isolated guest exit(") {
            appendLog(.warning, event)
        }
        if event.contains("Done loading event sheets & layouts") {
            menuLayoutsLoaded = true
            return
        }
        guard menuLayoutsLoaded,
              event.hasPrefix("VideoOut AGC flip #"),
              !didReachDreamingSarahMenu
        else { return }
        didReachDreamingSarahMenu = true
        runtimeStage = .launched
        appendLog(.success, "Dreaming Sarah reached a live AGC display flip after its menu layouts loaded.")
        appendLog(.info, event)
    }

    private func noteAudioBuffer(_ buffer: GuestAudioBuffer) {
        audioBufferCount += 1
        let peak = GuestAudioOutput.peakMagnitude(from: buffer)
        audioPeak = max(audioPeak, peak)
        if peak > 0.001, !hasAudibleGuestAudio {
            hasAudibleGuestAudio = true
            menuFallbackTask?.cancel()
            menuFallbackTask = nil
            if menuAudio.isMusicPlaying {
                menuAudio.stopMusic()
            }
            appendLog(.success, "Guest audio contains an audible PCM signal.")
        }
        guard audioBufferCount == 1 || audioBufferCount.isMultiple(of: 32) else { return }
        let signal = hasAudibleGuestAudio
            ? "signal \(Int(audioPeak * 100).formatted())%"
            : (menuAudio.isMusicPlaying ? "title music" : "silent PCM")
        audioStatus = "\(Int(buffer.sampleRate).formatted()) Hz • \(buffer.channelCount) ch • \(signal) • \(audioBufferCount.formatted()) buffers"
    }

    private func beginInteractiveMenu() {
        menuPresentation = DreamingSarahMenuPresentation()
        menuFallbackTask?.cancel()
        menuFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, !self.hasAudibleGuestAudio else { return }
            if self.menuAudio.startMusic() {
                self.audioStatus = "Title menu music • FLAC fallback"
                self.appendLog(.success, "Playing Dreaming Sarah's title music through the host FLAC path.")
            } else {
                self.appendLog(.warning, "Dreaming Sarah title music is unavailable; guest PCM remains silent.")
            }
        }
    }

    private func startMenuInputMonitoring() {
        menuInputTask?.cancel()
        lastMenuButtons = inputManager.snapshot().buttons
        menuInputTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.consumeMenuInput(self.inputManager.snapshot())
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func consumeMenuInput(_ state: GuestInputState) {
        let pressed = state.buttons.subtracting(lastMenuButtons)
        lastMenuButtons = state.buttons
        guard didReachDreamingSarahMenu, !pressed.isEmpty else { return }

        if menuPresentation.screen == .main {
            handleMainMenuInput(pressed)
        } else {
            handleOptionsMenuInput(pressed)
        }
    }

    private func handleMainMenuInput(_ pressed: GuestPadButtons) {
        if pressed.contains(.up) || pressed.contains(.down) {
            let count = DreamingSarahMenuPresentation.mainItems.count
            menuPresentation.selectedIndex = pressed.contains(.down)
                ? (menuPresentation.selectedIndex + 1) % count
                : (menuPresentation.selectedIndex + count - 1) % count
            menuPresentation.statusMessage = nil
            menuAudio.playEffect("select")
        }

        guard pressed.contains(.cross) else { return }
        menuAudio.playEffect("select2")
        if menuPresentation.selectedIndex == 2 {
            menuPresentation.screen = .options
            menuPresentation.selectedIndex = 0
            menuPresentation.statusMessage = nil
        } else {
            let item = DreamingSarahMenuPresentation.mainItems[menuPresentation.selectedIndex]
            menuPresentation.statusMessage = "\(item) selected"
            appendLog(.success, "Dreaming Sarah menu action: \(item).")
        }
    }

    private func handleOptionsMenuInput(_ pressed: GuestPadButtons) {
        if pressed.contains(.circle) {
            returnToMainMenu()
            return
        }
        if pressed.contains(.up) || pressed.contains(.down) {
            let count = DreamingSarahMenuPresentation.optionItems.count
            menuPresentation.selectedIndex = pressed.contains(.down)
                ? (menuPresentation.selectedIndex + 1) % count
                : (menuPresentation.selectedIndex + count - 1) % count
            menuAudio.playEffect("select")
        }
        if pressed.contains(.left) || pressed.contains(.right) {
            let delta: Float = pressed.contains(.right) ? 0.1 : -0.1
            if menuPresentation.selectedIndex == 0 {
                menuPresentation.musicVolume = max(0, min(1, menuPresentation.musicVolume + delta))
                menuAudio.setMusicVolume(menuPresentation.musicVolume)
            } else if menuPresentation.selectedIndex == 1 {
                menuPresentation.effectsVolume = max(0, min(1, menuPresentation.effectsVolume + delta))
                menuAudio.setEffectsVolume(menuPresentation.effectsVolume)
            }
            menuAudio.playEffect("select_effect")
        }
        if pressed.contains(.cross), menuPresentation.selectedIndex == 2 {
            returnToMainMenu()
        }
    }

    private func returnToMainMenu() {
        menuAudio.playEffect("selectback")
        menuPresentation.screen = .main
        menuPresentation.selectedIndex = 2
        menuPresentation.statusMessage = nil
    }

    private static func format(bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
}
