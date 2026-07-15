// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5.data

data class LibraryFolder(
    val uri: String,
    val displayName: String,
)

data class Game(
    val id: String,
    val rootUri: String,
    val name: String,
    val titleId: String?,
    val executableUri: String,
    val executableSize: Long,
    val coverUri: String?,
) {
    val initials: String
        get() = name.split(Regex("\\s+"))
            .filter(String::isNotBlank)
            .take(2)
            .mapNotNull { it.firstOrNull()?.uppercaseChar() }
            .joinToString("")
            .ifBlank { "?" }
}

enum class RuntimeStage(val label: String) {
    Idle("Idle"),
    Preparing("Preparing"),
    Ready("Image Ready"),
    InputDemo("Input/Audio Demo"),
    Failed("Failed"),
}

enum class LogSeverity(val label: String) {
    Debug("DEBUG"),
    Info("INFO"),
    Success("OK"),
    Warning("WARN"),
    Error("ERROR"),
}

data class RuntimeLog(
    val timestampMillis: Long = System.currentTimeMillis(),
    val severity: LogSeverity,
    val message: String,
)

data class ExecutableReport(
    val format: String,
    val entryPoint: Long,
    val programHeaderCount: Int,
    val loadableSegmentCount: Int,
    val reservedMemoryBytes: Long,
    val encryptedSegmentCount: Int,
    val compressedSegmentCount: Int,
    val abiVersion: Int,
)

enum class Destination(val label: String) {
    Library("Library"),
    Runtime("Runtime"),
    Settings("Settings"),
}

enum class MenuScreen {
    Main,
    Options,
}

data class MenuPresentation(
    val screen: MenuScreen = MenuScreen.Main,
    val selectedIndex: Int = 0,
    val musicVolume: Float = 0.7f,
    val effectsVolume: Float = 0.9f,
    val statusMessage: String? = null,
) {
    val items: List<String>
        get() = when (screen) {
            MenuScreen.Main -> listOf("New game", "Continue", "Options")
            MenuScreen.Options -> listOf("Music volume", "Effects volume", "Back")
        }
}
