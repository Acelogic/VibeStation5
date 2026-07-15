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
}
