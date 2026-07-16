// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5.core

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.json.JSONObject

data class NativeRunResult(
    val instructionCount: Long,
    val totalInstructionCount: Long,
    val instructionPointer: String,
    val returnValue: String,
    val interceptedImports: Long,
    val gpuSubmissions: Long,
    val gpuDraws: Long,
    val gpuFlips: Long,
    val videoSequence: Long,
    val frameHash: String,
    val shaderCacheMisses: Long,
    val textureRefreshes: Long,
    val eventQueueDepth: Long,
    val lastImport: String,
    val terminal: Boolean,
    val reason: String,
    val recentInstructions: List<String>,
    val recentImports: List<String>,
    val observedImports: List<String>,
    val threadDiagnostics: List<String>,
)

class NativeGuestRuntime(executable: ByteArray, contentRoot: String? = null) : AutoCloseable {
    private var handle = NativeBridge.nativeCreateRuntime(executable, contentRoot).also {
        check(it != 0L) { "The native Android guest runtime could not be created." }
    }

    val description: String
        get() = NativeBridge.nativeRuntimeDescription(requiredHandle())

    @Synchronized
    fun run(instructionBudget: Long): NativeRunResult {
        val json = JSONObject(NativeBridge.nativeRunRuntime(requiredHandle(), instructionBudget))
        return NativeRunResult(
            instructionCount = json.getLong("instructionCount"),
            totalInstructionCount = json.getLong("totalInstructionCount"),
            instructionPointer = json.getString("instructionPointer"),
            returnValue = json.getString("returnValue"),
            interceptedImports = json.getLong("interceptedImports"),
            gpuSubmissions = json.getLong("gpuSubmissions"),
            gpuDraws = json.getLong("gpuDraws"),
            gpuFlips = json.getLong("gpuFlips"),
            videoSequence = json.getLong("videoSequence"),
            frameHash = json.getString("frameHash"),
            shaderCacheMisses = json.getLong("shaderCacheMisses"),
            textureRefreshes = json.getLong("textureRefreshes"),
            eventQueueDepth = json.getLong("eventQueueDepth"),
            lastImport = json.getString("lastImport"),
            terminal = json.getBoolean("terminal"),
            reason = json.getString("reason"),
            recentInstructions = json.getJSONArray("recentInstructions").toStringList(),
            recentImports = json.getJSONArray("recentImports").toStringList(),
            observedImports = json.getJSONArray("observedImports").toStringList(),
            threadDiagnostics = json.getJSONArray("threadDiagnostics").toStringList(),
        )
    }

    @Synchronized
    fun setInput(buttons: Long, leftX: Float = 0f, leftY: Float = 0f, rightX: Float = 0f, rightY: Float = 0f) {
        NativeBridge.nativeSetInput(requiredHandle(), buttons, leftX, leftY, rightX, rightY)
    }

    @Synchronized
    fun drainAudio(): GuestAudioChunk {
        val runtimeHandle = requiredHandle()
        return GuestAudioChunk(
            pcm16Stereo = NativeBridge.nativeDrainAudio(runtimeHandle),
            sampleRate = NativeBridge.nativeAudioSampleRate(runtimeHandle),
        )
    }

    @Synchronized
    fun readVideoFrame(afterSequence: Long): GuestVideoFrame? {
        val packet = NativeBridge.nativeReadVideoFrame(requiredHandle(), afterSequence)
        if (packet.isEmpty()) return null
        check(packet.size >= VIDEO_FRAME_HEADER_SIZE) { "The native video frame header is truncated." }

        val buffer = ByteBuffer.wrap(packet).order(ByteOrder.LITTLE_ENDIAN)
        val width = buffer.int
        val height = buffer.int
        val sequence = buffer.long
        val expectedSize = VIDEO_FRAME_HEADER_SIZE.toLong() + width.toLong() * height.toLong() * 4L
        check(width > 0 && height > 0 && expectedSize == packet.size.toLong()) {
            "The native video frame payload is invalid."
        }
        return GuestVideoFrame(
            bgra8888 = ByteArray(packet.size - VIDEO_FRAME_HEADER_SIZE).also(buffer::get),
            width = width,
            height = height,
            sequence = sequence,
        )
    }

    @Synchronized
    fun dumpGpuCapture(directory: File): File {
        check(directory.exists() || directory.mkdirs()) {
            "The GPU capture directory could not be created: ${directory.absolutePath}"
        }
        return File(NativeBridge.nativeDumpGpuCapture(requiredHandle(), directory.absolutePath))
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) {
            NativeBridge.nativeDestroyRuntime(handle)
            handle = 0
        }
    }

    private fun requiredHandle(): Long = handle.also {
        check(it != 0L) { "The native Android guest runtime is closed." }
    }

    private companion object {
        const val VIDEO_FRAME_HEADER_SIZE = 16
    }
}

data class GuestAudioChunk(
    val pcm16Stereo: ByteArray,
    val sampleRate: Int,
)

data class GuestVideoFrame(
    val bgra8888: ByteArray,
    val width: Int,
    val height: Int,
    val sequence: Long,
)

private fun org.json.JSONArray.toStringList(): List<String> =
    List(length()) { index -> getString(index) }
