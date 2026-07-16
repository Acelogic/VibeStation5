// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5.core

internal object NativeBridge {
    val available: Boolean = runCatching {
        System.loadLibrary("vibestation5_native")
        true
    }.getOrDefault(false)

    external fun nativeInspect(data: ByteArray): LongArray
    external fun nativeBackendInfo(): String
    external fun nativeCreateRuntime(data: ByteArray, contentRoot: String?): Long
    external fun nativeDestroyRuntime(handle: Long)
    external fun nativeRuntimeDescription(handle: Long): String
    external fun nativeRunRuntime(handle: Long, instructionBudget: Long): String
    external fun nativeSetInput(
        handle: Long,
        buttons: Long,
        leftX: Float,
        leftY: Float,
        rightX: Float,
        rightY: Float,
    )
    external fun nativeDrainAudio(handle: Long): ByteArray
    external fun nativeAudioSampleRate(handle: Long): Int
    external fun nativeReadVideoFrame(handle: Long, afterSequence: Long): ByteArray
    external fun nativeDumpGpuCapture(handle: Long, directory: String): String
}
