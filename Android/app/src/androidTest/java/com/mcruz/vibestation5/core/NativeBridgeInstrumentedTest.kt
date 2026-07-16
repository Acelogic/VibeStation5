// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5.core

import android.system.Os
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeBridgeInstrumentedTest {
    @Test
    fun nativeInspectorParsesX8664ElfOnAndroid() {
        assertTrue(NativeBridge.available)
        val data = ByteArray(64 + 56).apply {
            this[0] = 0x7F
            this[1] = 'E'.code.toByte()
            this[2] = 'L'.code.toByte()
            this[3] = 'F'.code.toByte()
            this[4] = 2
            this[5] = 1
            putU16le(18, 0x3E)
            putU64le(24, 0x800000070L)
            putU64le(32, 64)
            putU16le(52, 64)
            putU16le(54, 56)
            putU16le(56, 1)
            putU32le(64, 1)
            putU64le(64 + 32, 0x100)
            putU64le(64 + 40, 0x200)
        }

        val report = NativeBridge.nativeInspect(data)

        assertEquals(8, report.size)
        assertEquals(0L, report[0])
        assertEquals(0x800000070L, report[1])
        assertEquals(1L, report[3])
        assertEquals(0x200L, report[4])
        assertTrue(NativeBridge.nativeBackendInfo().contains("executable-memory="))
    }

    @Test
    fun nativeRuntimeExecutesX8664GuestCodeOnAndroid() {
        val code = byteArrayOf(
            0xB8.toByte(), 0x2A, 0, 0, 0, // mov eax, 42
            0xC3.toByte(), // ret
        )
        val elf = ByteArray(0x1000 + code.size).apply {
            this[0] = 0x7F
            this[1] = 'E'.code.toByte()
            this[2] = 'L'.code.toByte()
            this[3] = 'F'.code.toByte()
            this[4] = 2
            this[5] = 1
            this[6] = 1
            putU16le(16, 3)
            putU16le(18, 0x3E)
            putU32le(20, 1)
            putU64le(24, 0x10000)
            putU64le(32, 64)
            putU16le(52, 64)
            putU16le(54, 56)
            putU16le(56, 1)
            putU32le(64, 1)
            putU32le(68, 5)
            putU64le(72, 0x1000)
            putU64le(80, 0x10000)
            putU64le(96, code.size.toLong())
            putU64le(104, 0x1000)
            putU64le(112, 0x1000)
            code.copyInto(this, 0x1000)
        }

        NativeGuestRuntime(elf).use { runtime ->
            assertTrue(runtime.description.contains("entry=0x0000000000010000"))
            val result = runtime.run(16)

            assertEquals("sentinel return", result.reason)
            assertTrue(result.terminal)
            assertEquals("0x000000000000002A", result.returnValue)
            assertEquals(2L, result.totalInstructionCount)
            assertNull(runtime.readVideoFrame(0))
        }
    }

    @Test
    fun nativeRuntimeBootsSideloadedDreamingSarahImageWhenPresent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val executable = listOfNotNull(
            File(context.filesDir, "PPSA02929-app0/eboot.bin"),
            context.getExternalFilesDir(null)?.let { File(it, "PPSA02929-app0/eboot.bin") },
        ).firstOrNull(File::isFile) ?: File(context.filesDir, "PPSA02929-app0/eboot.bin")
        assumeTrue("Dreaming Sarah development image is not sideloaded", executable.isFile)

        NativeGuestRuntime(executable.readBytes(), executable.parentFile?.absolutePath).use { runtime ->
            assertTrue(runtime.description.contains("PS5 SELF"))
            var result = runtime.run(30_000_000)

            assertEquals(
                "Native stop after ${result.totalInstructionCount} instructions: ${result.reason}\nImports:\n${result.recentImports.joinToString("\n")}\nInstructions:\n${result.recentInstructions.joinToString("\n")}",
                30_000_000L,
                result.instructionCount,
            )
            assertTrue(result.totalInstructionCount >= 30_000_000L)
            assertTrue(result.recentInstructions.isNotEmpty())
            var audio = runtime.drainAudio()
            var audioByteCount = audio.pcm16Stereo.size.toLong()
            assertTrue("Dreaming Sarah did not submit guest PCM by the 30M checkpoint", audioByteCount > 0)

            while (!result.terminal && result.totalInstructionCount < 120_000_000L) {
                result = runtime.run(10_000_000)
                audio = runtime.drainAudio()
                audioByteCount += audio.pcm16Stereo.size
                Log.i(
                    "VibeStationNativeTest",
                    "Dreaming Sarah runtime wait: ${result.totalInstructionCount} instructions; submissions=${result.gpuSubmissions}; draws=${result.gpuDraws}; flips=${result.gpuFlips}",
                )
            }

            val frame = runtime.readVideoFrame(0)
            Log.i(
                "VibeStationNativeTest",
                "Dreaming Sarah GPU checkpoint: ${result.totalInstructionCount} instructions at ${result.instructionPointer}; submissions=${result.gpuSubmissions}; draws=${result.gpuDraws}; flips=${result.gpuFlips}; frame=${frame?.width}x${frame?.height}; frameHash=${result.frameHash}; textureRefreshes=${result.textureRefreshes}; shaderMisses=${result.shaderCacheMisses}; eventDepth=${result.eventQueueDepth}; lastImport=${result.lastImport}; audio=$audioByteCount bytes @ ${audio.sampleRate} Hz; terminal=${result.terminal}; reason=${result.reason}\nThreads:\n${result.threadDiagnostics.joinToString("\n")}\nObserved imports: ${result.observedImports.joinToString(", ")}\nRecent imports:\n${result.recentImports.joinToString("\n")}\nRecent instructions:\n${result.recentInstructions.joinToString("\n")}",
            )
            assertTrue(
                "Dreaming Sarah did not submit a DCB by the 120M checkpoint; " +
                    "terminal=${result.terminal}; reason=${result.reason}; ip=${result.instructionPointer}",
                result.gpuSubmissions > 0,
            )
            assertTrue("Dreaming Sarah did not submit a draw by the first DCB checkpoint", result.gpuDraws > 0)
            assertTrue("Dreaming Sarah did not submit a flip by the first DCB checkpoint", result.gpuFlips > 0)
            assertTrue("Dreaming Sarah did not present a guest buffer by the first DCB checkpoint", frame != null)
            assertTrue("Dreaming Sarah terminated before the 120M checkpoint: ${result.reason}", !result.terminal)
            val captureDirectory = File(context.filesDir, "gpu-capture-120m")
            frame?.let { File(captureDirectory, "frame-120m-${it.width}x${it.height}.bgra").apply {
                parentFile?.mkdirs()
                writeBytes(it.bgra8888)
            } }
            val manifest = runtime.dumpGpuCapture(captureDirectory)
            val memoryCapture = File(captureDirectory, "memory.vs5")
            Log.i(
                "VibeStationNativeTest",
                "Dreaming Sarah GPU capture: ${manifest.absolutePath}; manifest=${manifest.length()} bytes; memory=${memoryCapture.length()} bytes",
            )
            assertTrue("Dreaming Sarah GPU capture manifest was not written", manifest.isFile && manifest.length() > 0)
            assertTrue("Dreaming Sarah guest-memory capture was not written", memoryCapture.isFile && memoryCapture.length() > 24)
        }
    }

    @Test
    fun nativeRuntimeAdvancesDreamingSarahInTwentyFiveMillionInstructionChunksWhenPresent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val executable = listOfNotNull(
            File(context.filesDir, "PPSA02929-app0/eboot.bin"),
            context.getExternalFilesDir(null)?.let { File(it, "PPSA02929-app0/eboot.bin") },
        ).firstOrNull(File::isFile) ?: File(context.filesDir, "PPSA02929-app0/eboot.bin")
        assumeTrue("Dreaming Sarah development image is not sideloaded", executable.isFile)

        NativeGuestRuntime(executable.readBytes(), executable.parentFile?.absolutePath).use { runtime ->
            var result = runtime.run(25_000_000)
            var lastVideoSequence = 0L
            var audioByteCount = 0L
            val frameHashes = linkedSetOf<String>()
            while (!result.terminal && result.totalInstructionCount < 300_000_000L) {
                val audio = runtime.drainAudio()
                audioByteCount += audio.pcm16Stereo.size
                runtime.readVideoFrame(lastVideoSequence)?.let { frame ->
                    lastVideoSequence = frame.sequence
                    frameHashes += result.frameHash
                }
                Log.i(
                    "VibeStationNativeTest",
                    "Dreaming Sarah 25M progression: instructions=${result.totalInstructionCount}; ip=${result.instructionPointer}; " +
                        "frameHash=${result.frameHash}; videoSequence=${result.videoSequence}; frames=${frameHashes.size}; " +
                        "submissions=${result.gpuSubmissions}; draws=${result.gpuDraws}; flips=${result.gpuFlips}; " +
                        "textureRefreshes=${result.textureRefreshes}; shaderMisses=${result.shaderCacheMisses}; " +
                        "eventDepth=${result.eventQueueDepth}; lastImport=${result.lastImport}; audio=$audioByteCount; " +
                        "conditionWaiters=${result.threadDiagnostics.count { it.startsWith("condition ") }}; " +
                        "timedConditionWaiters=${result.threadDiagnostics.count { it.startsWith("condition ") && it.endsWith("timed=true") }}; " +
                        "terminal=${result.terminal}; reason=${result.reason}",
                )
                if (!result.terminal) result = runtime.run(25_000_000)
            }
            Log.i(
                "VibeStationNativeTest",
                "Dreaming Sarah extended stop: instructions=${result.totalInstructionCount}; ip=${result.instructionPointer}; " +
                    "frameHash=${result.frameHash}; distinctFrames=${frameHashes.size}; lastImport=${result.lastImport}; " +
                    "terminal=${result.terminal}; reason=${result.reason}\n" +
                    "Threads:\n${result.threadDiagnostics.joinToString("\n")}\n" +
                "Recent imports:\n${result.recentImports.joinToString("\n")}\n" +
                    "Observed imports:\n${result.observedImports.joinToString("\n")}\n" +
                    "Recent instructions:\n${result.recentInstructions.joinToString("\n")}",
            )
            assertTrue("Dreaming Sarah terminated during extended progression: ${result.reason}", !result.terminal)
            assertTrue("Dreaming Sarah did not present a frame during extended progression", result.videoSequence > 0)
            assertTrue("Dreaming Sarah did not produce audio during extended progression", audioByteCount > 0)
        }
    }

    @Test
    fun nativeRuntimeFastForwardsDreamingSarahContentLoadingWhenPresent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val executable = listOfNotNull(
            File(context.filesDir, "PPSA02929-app0/eboot.bin"),
            context.getExternalFilesDir(null)?.let { File(it, "PPSA02929-app0/eboot.bin") },
        ).firstOrNull(File::isFile) ?: File(context.filesDir, "PPSA02929-app0/eboot.bin")
        assumeTrue("Dreaming Sarah development image is not sideloaded", executable.isFile)

        Os.setenv("VS5_FAST_FORWARD_WAITS", "1", true)
        Os.setenv("VS5_DISABLE_VULKAN", "1", true)
        try {
            NativeGuestRuntime(executable.readBytes(), executable.parentFile?.absolutePath).use { runtime ->
                var result = runtime.run(25_000_000)
                var layoutsLoaded = result.threadDiagnostics.any { it.startsWith("content layoutsLoaded=true") }
                while (!result.terminal && !layoutsLoaded && result.totalInstructionCount < 500_000_000L) {
                    Log.i(
                        "VibeStationNativeTest",
                        "Dreaming Sarah fast progression: instructions=${result.totalInstructionCount}; " +
                            "ip=${result.instructionPointer}; layoutsLoaded=$layoutsLoaded; " +
                            "draws=${result.gpuDraws}; flips=${result.gpuFlips}; lastImport=${result.lastImport}; " +
                            "isfinite=${result.threadDiagnostics.firstOrNull { it.startsWith("hle isfiniteCalls=") }}; " +
                            "terminal=${result.terminal}; reason=${result.reason}",
                    )
                    result = runtime.run(25_000_000)
                    layoutsLoaded = result.threadDiagnostics.any { it.startsWith("content layoutsLoaded=true") }
                }
                Log.i(
                    "VibeStationNativeTest",
                    "Dreaming Sarah fast stop: instructions=${result.totalInstructionCount}; " +
                        "ip=${result.instructionPointer}; layoutsLoaded=$layoutsLoaded; terminal=${result.terminal}; " +
                        "reason=${result.reason}\nThreads:\n${result.threadDiagnostics.joinToString("\n")}\n" +
                        "Recent imports:\n${result.recentImports.joinToString("\n")}\n" +
                        "Observed imports:\n${result.observedImports.joinToString("\n")}",
                )
                assertTrue("Dreaming Sarah terminated during fast progression: ${result.reason}", !result.terminal)
                assertTrue(
                    "Dreaming Sarah did not complete event-sheet and layout loading by ${result.totalInstructionCount} instructions",
                    layoutsLoaded,
                )
            }
        } finally {
            Os.unsetenv("VS5_DISABLE_VULKAN")
            Os.unsetenv("VS5_FAST_FORWARD_WAITS")
        }
    }

    @Test
    fun nativeRuntimeProfilesDreamingSarahContentLoaderWhenPresent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val executable = listOfNotNull(
            File(context.filesDir, "PPSA02929-app0/eboot.bin"),
            context.getExternalFilesDir(null)?.let { File(it, "PPSA02929-app0/eboot.bin") },
        ).firstOrNull(File::isFile) ?: File(context.filesDir, "PPSA02929-app0/eboot.bin")
        assumeTrue("Dreaming Sarah development image is not sideloaded", executable.isFile)

        Os.setenv("VS5_FAST_FORWARD_WAITS", "1", true)
        Os.setenv("VS5_DISABLE_VULKAN", "1", true)
        try {
            NativeGuestRuntime(executable.readBytes(), executable.parentFile?.absolutePath).use { runtime ->
                var result = runtime.run(25_000_000)
                while (!result.terminal && result.totalInstructionCount < 175_000_000L) {
                    result = runtime.run(25_000_000)
                }
                Log.i(
                    "VibeStationNativeTest",
                    "Dreaming Sarah loader profile: instructions=${result.totalInstructionCount}; " +
                        "terminal=${result.terminal}; reason=${result.reason}\n" +
                        result.threadDiagnostics.joinToString("\n"),
                )
                assertTrue("Dreaming Sarah terminated during loader profiling: ${result.reason}", !result.terminal)
                val fusedCopies = result.threadDiagnostics
                    .firstOrNull { it.startsWith("fusion circularStereoCopies=") }
                    ?.substringAfter('=')
                    ?.substringBefore(' ')
                    ?.toLongOrNull() ?: 0L
                assertTrue("Dreaming Sarah circular stereo-copy loop was not fused", fusedCopies > 0)
            }
        } finally {
            Os.unsetenv("VS5_DISABLE_VULKAN")
            Os.unsetenv("VS5_FAST_FORWARD_WAITS")
        }
    }

    @Test
    fun nativeRuntimeReportsDreamingSarahThreadStateWhenPresent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val executable = listOfNotNull(
            File(context.filesDir, "PPSA02929-app0/eboot.bin"),
            context.getExternalFilesDir(null)?.let { File(it, "PPSA02929-app0/eboot.bin") },
        ).firstOrNull(File::isFile) ?: File(context.filesDir, "PPSA02929-app0/eboot.bin")
        assumeTrue("Dreaming Sarah development image is not sideloaded", executable.isFile)

        NativeGuestRuntime(executable.readBytes(), executable.parentFile?.absolutePath).use { runtime ->
            val result = runtime.run(5_000_000)
            Log.i(
                "VibeStationNativeTest",
                "Dreaming Sarah 5M checkpoint: ip=${result.instructionPointer}; hle=${result.interceptedImports}; " +
                    "submissions=${result.gpuSubmissions}; draws=${result.gpuDraws}; flips=${result.gpuFlips}\n" +
                    "Threads:\n${result.threadDiagnostics.joinToString("\n")}\n" +
                    "Observed: ${result.observedImports.joinToString(", ")}\n" +
                    "Recent:\n${result.recentImports.joinToString("\n")}",
            )
            assertTrue("Dreaming Sarah terminated before the scheduler checkpoint: ${result.reason}", !result.terminal)
        }
    }

    private fun ByteArray.putU16le(offset: Int, value: Int) {
        this[offset] = value.toByte()
        this[offset + 1] = (value ushr 8).toByte()
    }

    private fun ByteArray.putU32le(offset: Int, value: Int) {
        repeat(4) { index -> this[offset + index] = (value ushr (index * 8)).toByte() }
    }

    private fun ByteArray.putU64le(offset: Int, value: Long) {
        repeat(8) { index -> this[offset + index] = (value ushr (index * 8)).toByte() }
    }
}
