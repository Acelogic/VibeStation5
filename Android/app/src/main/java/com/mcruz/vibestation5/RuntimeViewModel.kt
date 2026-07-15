// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5

import android.app.Application
import android.content.Intent
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import com.mcruz.vibestation5.core.ExecutableInspector
import com.mcruz.vibestation5.data.Destination
import com.mcruz.vibestation5.data.ExecutableReport
import com.mcruz.vibestation5.data.Game
import com.mcruz.vibestation5.data.GameLibraryRepository
import com.mcruz.vibestation5.data.LibraryFolder
import com.mcruz.vibestation5.data.LogSeverity
import com.mcruz.vibestation5.data.MenuPresentation
import com.mcruz.vibestation5.data.MenuScreen
import com.mcruz.vibestation5.data.RuntimeLog
import com.mcruz.vibestation5.data.RuntimeStage
import com.mcruz.vibestation5.input.GuestAction
import com.mcruz.vibestation5.input.GuestInputRouter
import kotlinx.coroutines.launch

data class VibeStationState(
    val folders: List<LibraryFolder> = emptyList(),
    val games: List<Game> = emptyList(),
    val scanIssues: List<String> = emptyList(),
    val selectedGameId: String? = null,
    val destination: Destination = Destination.Library,
    val stage: RuntimeStage = RuntimeStage.Idle,
    val preparation: ExecutableReport? = null,
    val logs: List<RuntimeLog> = emptyList(),
    val inputStatus: String = "Touch controls + keyboard + gamepad",
    val audioStatus: String = "Android audio cues ready",
    val menu: MenuPresentation = MenuPresentation(),
    val isScanning: Boolean = false,
    val demoActive: Boolean = false,
    val errorMessage: String? = null,
    val nativeBackend: String = "JNI unavailable",
)

class RuntimeViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = GameLibraryRepository(application)
    private val inspector = ExecutableInspector()
    private val audio = MenuAudioCues()

    var state by androidx.compose.runtime.mutableStateOf(
        VibeStationState(
            folders = repository.loadFolders(),
            nativeBackend = inspector.backendDescription(),
        ),
    )
        private set

    val input = GuestInputRouter(::consumeInput).apply {
        statusHandler = { status -> state = state.copy(inputStatus = status) }
    }

    init {
        appendLog(LogSeverity.Info, "VibeStation5 Android runtime initialized.")
        appendLog(LogSeverity.Info, "Native backend: ${state.nativeBackend}.")
        appendLog(LogSeverity.Info, "Android loader/preflight is available; guest CPU execution is not yet ported.")
        if (state.folders.isNotEmpty()) refreshLibrary()
    }

    val selectedGame: Game?
        get() = state.games.firstOrNull { it.id == state.selectedGameId }

    fun selectDestination(destination: Destination) {
        state = state.copy(destination = destination)
    }

    fun addFolder(uri: Uri) {
        runCatching {
            getApplication<Application>().contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
            repository.addFolder(uri, state.folders)
        }.onSuccess { folders ->
            state = state.copy(folders = folders)
            appendLog(LogSeverity.Success, "Added Android library folder.")
            refreshLibrary()
        }.onFailure(::showError)
    }

    fun removeFolder(uri: String) {
        val folders = repository.removeFolder(uri, state.folders)
        state = state.copy(folders = folders)
        appendLog(LogSeverity.Info, "Removed Android library folder.")
        refreshLibrary()
    }

    fun refreshLibrary() {
        if (state.isScanning) return
        state = state.copy(isScanning = true)
        appendLog(LogSeverity.Info, "Scanning ${state.folders.size} Android library folder(s)…")
        viewModelScope.launch {
            runCatching { repository.scan(state.folders) }
                .onSuccess { (games, issues) ->
                    val selection = state.selectedGameId?.takeIf { id -> games.any { it.id == id } }
                        ?: games.firstOrNull()?.id
                    state = state.copy(
                        games = games,
                        scanIssues = issues,
                        selectedGameId = selection,
                        isScanning = false,
                    )
                    appendLog(LogSeverity.Success, "Library scan complete: ${games.size} game(s).")
                    issues.forEach { appendLog(LogSeverity.Warning, it) }
                }
                .onFailure {
                    state = state.copy(isScanning = false)
                    showError(it)
                }
        }
    }

    fun selectGame(id: String) {
        state = state.copy(selectedGameId = id, preparation = null, stage = RuntimeStage.Idle, demoActive = false)
    }

    fun prepareSelectedGame() {
        val game = selectedGame ?: run {
            showError(IllegalStateException("Select a game before preparing the Android runtime."))
            return
        }
        state = state.copy(stage = RuntimeStage.Preparing, preparation = null, demoActive = false)
        appendLog(LogSeverity.Info, "Inspecting ${game.name} on Android…")
        viewModelScope.launch {
            runCatching {
                inspector.inspect(getApplication<Application>().contentResolver, Uri.parse(game.executableUri))
            }.onSuccess { report ->
                state = state.copy(stage = RuntimeStage.Ready, preparation = report)
                appendLog(
                    LogSeverity.Success,
                    "Prepared ${report.format}: ${report.loadableSegmentCount} loadable segment(s), entry ${hex(report.entryPoint)}.",
                )
                if (report.encryptedSegmentCount > 0 || report.compressedSegmentCount > 0) {
                    appendLog(
                        LogSeverity.Warning,
                        "This image still has ${report.encryptedSegmentCount} encrypted and ${report.compressedSegmentCount} compressed SELF segment(s).",
                    )
                }
            }.onFailure {
                state = state.copy(stage = RuntimeStage.Failed)
                showError(it)
            }
        }
    }

    fun startInputAudioDemo() {
        if (state.preparation == null) {
            showError(IllegalStateException("Prepare a game before starting the input/audio demo."))
            return
        }
        state = state.copy(
            stage = RuntimeStage.InputDemo,
            demoActive = true,
            destination = Destination.Runtime,
            menu = MenuPresentation(statusMessage = "Android compatibility preview"),
        )
        audio.confirm(state.menu.effectsVolume)
        appendLog(LogSeverity.Success, "Android touch, keyboard, gamepad, and audio demo started.")
        appendLog(LogSeverity.Warning, "This is a native UI compatibility preview; x86-64 guest execution remains an Apple-target-only milestone.")
    }

    fun stopDemo() {
        state = state.copy(
            stage = if (state.preparation != null) RuntimeStage.Ready else RuntimeStage.Idle,
            demoActive = false,
        )
        appendLog(LogSeverity.Info, "Android input/audio demo stopped.")
    }

    fun clearLogs() {
        state = state.copy(logs = emptyList())
    }

    fun consumeError() {
        state = state.copy(errorMessage = null)
    }

    private fun consumeInput(action: GuestAction) {
        if (!state.demoActive) return
        when (action) {
            GuestAction.Up -> moveSelection(-1)
            GuestAction.Down -> moveSelection(1)
            GuestAction.Left -> adjustOption(-0.05f)
            GuestAction.Right -> adjustOption(0.05f)
            GuestAction.Confirm -> confirmSelection()
            GuestAction.Back -> navigateBack()
            GuestAction.Options -> {
                state = state.copy(menu = state.menu.copy(screen = MenuScreen.Options, selectedIndex = 0))
                audio.confirm(state.menu.effectsVolume)
            }
        }
    }

    private fun moveSelection(delta: Int) {
        val count = state.menu.items.size
        val selected = (state.menu.selectedIndex + delta + count) % count
        state = state.copy(menu = state.menu.copy(selectedIndex = selected, statusMessage = null))
        audio.navigate(state.menu.effectsVolume)
    }

    private fun adjustOption(delta: Float) {
        val menu = state.menu
        if (menu.screen != MenuScreen.Options) return
        val changed = when (menu.selectedIndex) {
            0 -> menu.copy(musicVolume = (menu.musicVolume + delta).coerceIn(0f, 1f))
            1 -> menu.copy(effectsVolume = (menu.effectsVolume + delta).coerceIn(0f, 1f))
            else -> return
        }
        state = state.copy(menu = changed)
        audio.navigate(changed.effectsVolume)
    }

    private fun confirmSelection() {
        val menu = state.menu
        if (menu.screen == MenuScreen.Main && menu.selectedIndex == 2) {
            state = state.copy(menu = menu.copy(screen = MenuScreen.Options, selectedIndex = 0))
        } else if (menu.screen == MenuScreen.Options && menu.selectedIndex == 2) {
            state = state.copy(menu = menu.copy(screen = MenuScreen.Main, selectedIndex = 2))
        } else {
            state = state.copy(menu = menu.copy(statusMessage = "Guest CPU backend is not connected on Android yet"))
        }
        audio.confirm(state.menu.effectsVolume)
    }

    private fun navigateBack() {
        if (state.menu.screen == MenuScreen.Options) {
            state = state.copy(menu = state.menu.copy(screen = MenuScreen.Main, selectedIndex = 2))
            audio.confirm(state.menu.effectsVolume)
        } else {
            stopDemo()
        }
    }

    private fun appendLog(severity: LogSeverity, message: String) {
        state = state.copy(logs = (state.logs + RuntimeLog(severity = severity, message = message)).takeLast(250))
    }

    private fun showError(error: Throwable) {
        val message = error.message ?: error::class.java.simpleName
        state = state.copy(errorMessage = message)
        appendLog(LogSeverity.Error, message)
    }

    private fun hex(value: Long): String = "0x%016X".format(value)

    override fun onCleared() {
        audio.close()
        super.onCleared()
    }
}

private class MenuAudioCues {
    private val generator = runCatching { ToneGenerator(AudioManager.STREAM_MUSIC, 90) }.getOrNull()

    fun navigate(volume: Float) {
        if (volume > 0.01f) generator?.startTone(ToneGenerator.TONE_PROP_BEEP, 45)
    }

    fun confirm(volume: Float) {
        if (volume > 0.01f) generator?.startTone(ToneGenerator.TONE_PROP_ACK, 80)
    }

    fun close() {
        generator?.release()
    }
}
