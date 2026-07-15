// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5.core

import android.content.ContentResolver
import android.net.Uri
import com.mcruz.vibestation5.data.ExecutableReport
import java.io.ByteArrayOutputStream

class ExecutableInspector {
    fun inspect(resolver: ContentResolver, uri: Uri): ExecutableReport {
        val prefix = resolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (output.size() < MAXIMUM_HEADER_BYTES) {
                val remaining = MAXIMUM_HEADER_BYTES - output.size()
                val count = input.read(buffer, 0, minOf(buffer.size, remaining))
                if (count <= 0) break
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        } ?: error("The executable could not be opened.")
        return parse(prefix)
    }

    fun parse(data: ByteArray): ExecutableReport {
        if (NativeBridge.available) {
            val values = NativeBridge.nativeInspect(data)
            require(values.size == 8) { "The native inspector returned an invalid report." }
            return ExecutableReport(
                format = when (values[0].toInt()) {
                    0 -> "Decrypted ELF"
                    1 -> "PS4 SELF"
                    2 -> "PS5 SELF"
                    else -> error("The native inspector returned an unknown executable format.")
                },
                entryPoint = values[1],
                programHeaderCount = values[2].toInt(),
                loadableSegmentCount = values[3].toInt(),
                reservedMemoryBytes = values[4],
                encryptedSegmentCount = values[5].toInt(),
                compressedSegmentCount = values[6].toInt(),
                abiVersion = values[7].toInt(),
            )
        }
        return parseKotlin(data)
    }

    fun backendDescription(): String = if (NativeBridge.available) {
        runCatching { NativeBridge.nativeBackendInfo() }.getOrDefault("JNI loaded; probe failed")
    } else {
        "JNI unavailable"
    }

    private fun parseKotlin(data: ByteArray): ExecutableReport {
        requireRange(data, 0, 4, "Executable magic")
        val magic = data.u32be(0)
        val format: String
        val elfOffset: Int
        var encryptedSegments = 0
        var compressedSegments = 0

        when (magic) {
            ELF_MAGIC -> {
                format = "Decrypted ELF"
                elfOffset = 0
            }
            PS4_SELF_MAGIC, PS5_SELF_MAGIC -> {
                requireRange(data, 0, SELF_HEADER_SIZE, "SELF header")
                val ps5 = magic == PS5_SELF_MAGIC
                val expected = if (ps5) PS5_IDENTIFIER else PS4_IDENTIFIER
                require(data.copyOfRange(0, expected.size).contentEquals(expected)) {
                    "The ${if (ps5) "PS5" else "PS4"} SELF header signature is not recognized."
                }
                val segmentCount = data.u16le(24)
                val layout = data.u16le(26)
                require(layout == if (ps5) 0x52 else 0x22) { "The SELF layout identifier is not recognized." }
                require(segmentCount <= MAXIMUM_SEGMENTS) { "The SELF segment table is unreasonably large." }
                elfOffset = SELF_HEADER_SIZE + segmentCount * SELF_SEGMENT_SIZE
                requireRange(data, 0, elfOffset + ELF_HEADER_SIZE, "SELF tables")
                repeat(segmentCount) { index ->
                    val type = data.u64le(SELF_HEADER_SIZE + index * SELF_SEGMENT_SIZE)
                    if ((type and 0x2L) != 0L) encryptedSegments++
                    if ((type and 0x8L) != 0L) compressedSegments++
                }
                format = if (ps5) "PS5 SELF" else "PS4 SELF"
            }
            else -> error("The file is neither a decrypted ELF nor a recognized PS4/PS5 SELF image.")
        }

        requireRange(data, elfOffset, ELF_HEADER_SIZE, "ELF header")
        require(data.u32be(elfOffset) == ELF_MAGIC) { "The executable does not have an ELF signature." }
        require(data.u8(elfOffset + 4) == 2) { "Only 64-bit ELF images are supported." }
        require(data.u8(elfOffset + 5) == 1) { "Only little-endian ELF images are supported." }
        require(data.u16le(elfOffset + 18) == AMD64_MACHINE) {
            "The ELF image is not the PS4/PS5 x86-64 architecture."
        }

        val abiVersion = data.u8(elfOffset + 8)
        val entryPoint = data.u64le(elfOffset + 24)
        val headerSize = data.u16le(elfOffset + 52)
        val programHeaderOffset = data.u64le(elfOffset + 32)
        val programHeaderEntrySize = data.u16le(elfOffset + 54)
        val programHeaderCount = data.u16le(elfOffset + 56)
        require(headerSize >= ELF_HEADER_SIZE) { "The ELF header size is invalid." }
        require(programHeaderCount <= MAXIMUM_PROGRAM_HEADERS) { "The program-header table is unreasonably large." }
        if (programHeaderCount > 0) {
            require(programHeaderEntrySize >= PROGRAM_HEADER_SIZE) { "The program-header entry is too small." }
        }
        require(programHeaderOffset in 0..Int.MAX_VALUE.toLong()) { "The program-header offset is invalid." }
        val tableStart = Math.addExact(elfOffset, programHeaderOffset.toInt())

        var loadableCount = 0
        var reservedBytes = 0L
        repeat(programHeaderCount) { index ->
            val offset = Math.addExact(tableStart, Math.multiplyExact(index, programHeaderEntrySize))
            requireRange(data, offset, PROGRAM_HEADER_SIZE, "ELF program header")
            val type = data.u32le(offset)
            val fileSize = data.u64le(offset + 32)
            val memorySize = data.u64le(offset + 40)
            if (type == LOAD_SEGMENT) {
                require(fileSize >= 0 && memorySize >= 0 && fileSize <= memorySize) {
                    "A loadable ELF segment is larger on disk than in memory."
                }
                loadableCount++
                reservedBytes = runCatching { Math.addExact(reservedBytes, memorySize) }.getOrElse { Long.MAX_VALUE }
            }
        }

        return ExecutableReport(
            format = format,
            entryPoint = entryPoint,
            programHeaderCount = programHeaderCount,
            loadableSegmentCount = loadableCount,
            reservedMemoryBytes = reservedBytes,
            encryptedSegmentCount = encryptedSegments,
            compressedSegmentCount = compressedSegments,
            abiVersion = abiVersion,
        )
    }

    private fun requireRange(data: ByteArray, offset: Int, count: Int, context: String) {
        require(offset >= 0 && count >= 0 && offset <= data.size - count) {
            "$context is truncated at offset $offset."
        }
    }

    private fun ByteArray.u8(offset: Int): Int = this[offset].toInt() and 0xFF

    private fun ByteArray.u16le(offset: Int): Int = u8(offset) or (u8(offset + 1) shl 8)

    private fun ByteArray.u32le(offset: Int): Long =
        u8(offset).toLong() or
            (u8(offset + 1).toLong() shl 8) or
            (u8(offset + 2).toLong() shl 16) or
            (u8(offset + 3).toLong() shl 24)

    private fun ByteArray.u32be(offset: Int): Long =
        (u8(offset).toLong() shl 24) or
            (u8(offset + 1).toLong() shl 16) or
            (u8(offset + 2).toLong() shl 8) or
            u8(offset + 3).toLong()

    private fun ByteArray.u64le(offset: Int): Long {
        var result = 0L
        repeat(8) { index -> result = result or (u8(offset + index).toLong() shl (index * 8)) }
        return result
    }

    private companion object {
        const val MAXIMUM_HEADER_BYTES = 8 * 1024 * 1024
        const val ELF_HEADER_SIZE = 64
        const val PROGRAM_HEADER_SIZE = 56
        const val SELF_HEADER_SIZE = 32
        const val SELF_SEGMENT_SIZE = 32
        const val MAXIMUM_SEGMENTS = 4096
        const val MAXIMUM_PROGRAM_HEADERS = 4096
        const val AMD64_MACHINE = 0x3E
        const val LOAD_SEGMENT = 1L
        const val ELF_MAGIC = 0x7F454C46L
        const val PS4_SELF_MAGIC = 0x4F153D1DL
        const val PS5_SELF_MAGIC = 0x5414F5EEL

        val PS4_IDENTIFIER = byteArrayOf(0x4F, 0x15, 0x3D, 0x1D, 0, 1, 1, 0x12, 1, 1, 0, 0)
        val PS5_IDENTIFIER = byteArrayOf(
            0x54, 0x14, 0xF5.toByte(), 0xEE.toByte(), 0x10, 1, 1, 0x32, 1, 3, 0, 0x10,
        )
    }
}
