// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
