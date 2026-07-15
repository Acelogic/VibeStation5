// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ExecutableInspectorTest {
    private val inspector = ExecutableInspector()

    @Test
    fun parsesDecryptedX8664Elf() {
        val data = makeElf()

        val report = inspector.parse(data)

        assertEquals("Decrypted ELF", report.format)
        assertEquals(0x800000070L, report.entryPoint)
        assertEquals(1, report.programHeaderCount)
        assertEquals(1, report.loadableSegmentCount)
        assertEquals(0x200L, report.reservedMemoryBytes)
    }

    @Test
    fun parsesPs5SelfAndReportsProtectedSegments() {
        val data = ByteArray(32 + 32 + 64 + 56)
        val identifier = byteArrayOf(
            0x54, 0x14, 0xF5.toByte(), 0xEE.toByte(), 0x10, 1, 1, 0x32, 1, 3, 0, 0x10,
        )
        identifier.copyInto(data)
        data.putU64le(16, data.size.toLong())
        data.putU16le(24, 1)
        data.putU16le(26, 0x52)
        data.putU64le(32, 0x80AL)
        makeElf().copyInto(data, destinationOffset = 64)

        val report = inspector.parse(data)

        assertEquals("PS5 SELF", report.format)
        assertEquals(1, report.encryptedSegmentCount)
        assertEquals(1, report.compressedSegmentCount)
    }

    @Test
    fun rejectsNonX8664Elf() {
        val data = makeElf()
        data.putU16le(18, 0xB7)

        assertThrows(IllegalArgumentException::class.java) { inspector.parse(data) }
    }

    @Test
    fun rejectsTruncatedProgramHeader() {
        val data = makeElf().copyOf(80)

        assertThrows(IllegalArgumentException::class.java) { inspector.parse(data) }
    }

    private fun makeElf(): ByteArray = ByteArray(64 + 56).apply {
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
        putU64le(24, 0x800000070L)
        putU64le(32, 64)
        putU16le(52, 64)
        putU16le(54, 56)
        putU16le(56, 1)
        putU32le(64, 1)
        putU32le(68, 5)
        putU64le(72, 0x1000)
        putU64le(80, 0x10000)
        putU64le(96, 0x100)
        putU64le(104, 0x200)
        putU64le(112, 0x1000)
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
