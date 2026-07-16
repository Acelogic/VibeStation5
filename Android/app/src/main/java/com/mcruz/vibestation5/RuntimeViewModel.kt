// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5

import android.app.Application
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import com.mcruz.vibestation5.core.ExecutableInspector
import com.mcruz.vibestation5.core.GuestVideoFrame
import com.mcruz.vibestation5.core.NativeGuestRuntime
import com.mcruz.vibestation5.core.NativeRunResult
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
import java.io.File
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    val audioStatus: String = "Guest audio HLE not initialized",
    val menu: MenuPresentation = MenuPresentation(),
    val isScanning: Boolean = false,
    val guestActive: Boolean = false,
    val guestStatus: String = "Native runtime idle",
    val guestInstructionCount: Long = 0,
    val guestImportCount: Long = 0,
    val guestFrame: GuestFramePresentation? = null,
    val errorMessage: String? = null,
    val nativeBackend: String = "JNI unavailable",
)

data class GuestFramePresentation(
    val width: Int,
    val height: Int,
    val argb8888: IntArray,
    val sequence: Long,
)

private data class LoadedRuntime(
    val runtime: NativeGuestRuntime,
    val report: ExecutableReport?,
    val gameName: String,
)

class RuntimeViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = GameLibraryRepository(application)
    private val inspector = ExecutableInspector()
    private var guestRuntime: NativeGuestRuntime? = null
    private var runtimeJob: Job? = null
    private var lastVideoSequence = 0L
    private val inputButtons = AtomicLong(0)
    private val audioSink = GuestAudioSink()

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
        appendLog(LogSeverity.Success, "Native Android SELF/ELF loader and x86-64 guest interpreter are online.")
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
        stopGuest(closeRuntime = true)
        state = state.copy(
            selectedGameId = id,
            preparation = null,
            stage = RuntimeStage.Idle,
            guestActive = false,
            guestStatus = "Native runtime idle",
            guestInstructionCount = 0,
            guestImportCount = 0,
            audioStatus = "Guest audio HLE not initialized",
        )
    }

    fun prepareSelectedGame() {
        val game = selectedGame ?: run {
            showError(IllegalStateException("Select a game before preparing the Android runtime."))
            return
        }
        stopGuest(closeRuntime = true)
        state = state.copy(stage = RuntimeStage.Preparing, preparation = null, guestActive = false)
        appendLog(LogSeverity.Info, "Loading ${game.name} into the native Android runtime…")
        viewModelScope.launch {
            runCatching {
                loadSelectedRuntime(game)
            }.onSuccess { loaded ->
                guestRuntime = loaded.runtime
                state = state.copy(
                    stage = RuntimeStage.Ready,
                    preparation = loaded.report,
                    guestStatus = loaded.runtime.description,
                )
                appendLog(
                    LogSeverity.Success,
                    "Prepared ${loaded.report?.format}: ${loaded.report?.loadableSegmentCount} loadable segment(s), entry ${hex(loaded.report?.entryPoint ?: 0)}.",
                )
                val report = loaded.report
                if (report != null && (report.encryptedSegmentCount > 0 || report.compressedSegmentCount > 0)) {
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

    fun launchDreamingSarah() {
        if (state.guestActive) {
            stopGuest()
            return
        }
        if (runtimeJob?.isActive == true) return

        val game = selectedGame
        state = state.copy(
            stage = RuntimeStage.Preparing,
            destination = Destination.Runtime,
            guestStatus = "Creating native Android guest process…",
            errorMessage = null,
        )
        runtimeJob = viewModelScope.launch {
            try {
                val loaded = guestRuntime?.let { LoadedRuntime(it, state.preparation, game?.name ?: "Dreaming Sarah") }
                    ?: loadRuntimeForLaunch(game)
                guestRuntime = loaded.runtime
                state = state.copy(
                    stage = RuntimeStage.Running,
                    preparation = loaded.report ?: state.preparation,
                    guestActive = true,
                    guestStatus = loaded.runtime.description,
                    audioStatus = "Guest audio HLE waiting for title initialization",
                )
                appendLog(LogSeverity.Success, "Executing ${loaded.gameName} through the native Android x86-64 interpreter.")
                runGuestLoop(loaded.runtime)
            } catch (_: CancellationException) {
                // A user stop or game change is a normal runtime transition.
            } catch (error: Throwable) {
                state = state.copy(stage = RuntimeStage.Failed, guestActive = false)
                showError(error)
            }
        }
    }

    fun stopGuest(closeRuntime: Boolean = false) {
        runtimeJob?.cancel()
        runtimeJob = null
        audioSink.release()
        inputButtons.set(0)
        guestRuntime?.setInput(0)
        if (closeRuntime) {
            guestRuntime?.close()
            guestRuntime = null
            lastVideoSequence = 0
        }
        state = state.copy(
            stage = if (state.preparation != null) RuntimeStage.Ready else RuntimeStage.Idle,
            guestActive = false,
            guestStatus = if (closeRuntime) "Native runtime idle" else "Native runtime paused",
            audioStatus = "Guest audio HLE not initialized",
            guestFrame = if (closeRuntime) null else state.guestFrame,
        )
        appendLog(LogSeverity.Info, if (closeRuntime) "Native guest process closed." else "Native guest execution paused.")
    }

    fun clearLogs() {
        state = state.copy(logs = emptyList())
    }

    fun consumeError() {
        state = state.copy(errorMessage = null)
    }

    private fun consumeInput(action: GuestAction) {
        if (!state.guestActive) return
        val mask = when (action) {
            GuestAction.Up -> 0x0010L
            GuestAction.Right -> 0x0020L
            GuestAction.Down -> 0x0040L
            GuestAction.Left -> 0x0080L
            GuestAction.Confirm -> 0x4000L
            GuestAction.Back -> 0x2000L
            GuestAction.Options -> 0x0008L
        }
        inputButtons.getAndUpdate { buttons -> buttons or mask }
        viewModelScope.launch {
            delay(120)
            inputButtons.getAndUpdate { buttons -> buttons and mask.inv() }
        }
    }

    private suspend fun loadSelectedRuntime(game: Game): LoadedRuntime = withContext(Dispatchers.IO) {
        val resolver = getApplication<Application>().contentResolver
        val uri = Uri.parse(game.executableUri)
        val report = inspector.inspect(resolver, uri)
        val executable = resolver.openInputStream(uri)?.use { it.readBytes() }
            ?: error("Android could not open ${game.name}'s executable.")
        val contentRoot = uri.path?.let(::File)?.parentFile?.absolutePath.takeIf { uri.scheme == "file" }
        LoadedRuntime(NativeGuestRuntime(executable, contentRoot), report, game.name)
    }

    private suspend fun loadRuntimeForLaunch(game: Game?): LoadedRuntime {
        if (game != null) return loadSelectedRuntime(game)
        return withContext(Dispatchers.IO) {
            val application = getApplication<Application>()
            val executable = listOfNotNull(
                File(application.filesDir, "PPSA02929-app0/eboot.bin"),
                application.getExternalFilesDir(null)?.let { File(it, "PPSA02929-app0/eboot.bin") },
            ).firstOrNull(File::isFile)
                ?: error("Select Dreaming Sarah from the Android library before launching it.")
            val report = runCatching {
                inspector.inspect(application.contentResolver, Uri.fromFile(executable))
            }.getOrNull()
            LoadedRuntime(NativeGuestRuntime(executable.readBytes(), executable.parentFile?.absolutePath), report, "Dreaming Sarah")
        }
    }

    private suspend fun runGuestLoop(runtime: NativeGuestRuntime) {
        while (currentCoroutineContext().isActive) {
            val slice = withContext(Dispatchers.Default) {
                runtime.setInput(inputButtons.get())
                val result = runtime.run(GUEST_TIMESLICE_INSTRUCTIONS)
                val audio = runtime.drainAudio()
                val frame = runtime.readVideoFrame(lastVideoSequence)?.toPresentation()
                if (audio.pcm16Stereo.isNotEmpty()) {
                    audioSink.write(audio.sampleRate, audio.pcm16Stereo)
                }
                GuestSlice(result, audio.pcm16Stereo.size, audio.sampleRate, frame)
            }
            val result = slice.result
            if (slice.audioBytes > 0) {
                state = state.copy(audioStatus = "Guest PCM16 stereo • ${slice.sampleRate} Hz • Android AudioTrack")
            }
            slice.frame?.let { frame ->
                lastVideoSequence = frame.sequence
                state = state.copy(guestFrame = frame)
            }
            publishRunResult(result)
            if (result.terminal) {
                state = state.copy(stage = RuntimeStage.Failed, guestActive = false)
                appendLog(LogSeverity.Error, "Native guest stopped: ${result.reason} at ${result.instructionPointer}.")
                result.recentInstructions.takeLast(8).forEach { appendLog(LogSeverity.Debug, it) }
                break
            }
        }
    }

    private fun publishRunResult(result: NativeRunResult) {
        state = state.copy(
            guestInstructionCount = result.totalInstructionCount,
            guestImportCount = result.interceptedImports,
            guestStatus = "${result.instructionPointer} • ${result.totalInstructionCount} instructions • ${result.interceptedImports} HLE calls • ${result.gpuDraws} draws • ${result.gpuFlips} flips",
        )
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
        runtimeJob?.cancel()
        audioSink.release()
        guestRuntime?.close()
        guestRuntime = null
        super.onCleared()
    }

    private companion object {
        const val GUEST_TIMESLICE_INSTRUCTIONS = 250_000L
    }
}

private data class GuestSlice(
    val result: NativeRunResult,
    val audioBytes: Int,
    val sampleRate: Int,
    val frame: GuestFramePresentation?,
)

private fun GuestVideoFrame.toPresentation(): GuestFramePresentation {
    val pixelCount = width * height
    val argb = IntArray(pixelCount)
    for (pixel in 0 until pixelCount) {
        val offset = pixel * 4
        val blue = bgra8888[offset].toInt() and 0xFF
        val green = bgra8888[offset + 1].toInt() and 0xFF
        val red = bgra8888[offset + 2].toInt() and 0xFF
        val alpha = bgra8888[offset + 3].toInt() and 0xFF
        argb[pixel] = (alpha shl 24) or (red shl 16) or (green shl 8) or blue
    }
    return GuestFramePresentation(width, height, argb, sequence)
}

private class GuestAudioSink {
    private var track: AudioTrack? = null
    private var sampleRate: Int = 0

    @Synchronized
    fun write(requestedSampleRate: Int, pcm16Stereo: ByteArray) {
        if (pcm16Stereo.isEmpty()) return
        val output = if (track == null || sampleRate != requestedSampleRate) {
            release()
            val minimum = AudioTrack.getMinBufferSize(
                requestedSampleRate,
                AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_GAME)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(requestedSampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(maxOf(minimum, 16 * 1024))
                .build()
                .also {
                    track = it
                    sampleRate = requestedSampleRate
                    it.play()
                }
        } else {
            checkNotNull(track)
        }
        output.write(pcm16Stereo, 0, pcm16Stereo.size, AudioTrack.WRITE_BLOCKING)
    }

    @Synchronized
    fun release() {
        track?.let { output ->
            runCatching { output.stop() }
            output.release()
        }
        track = null
        sampleRate = 0
    }
}
