// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5

import android.annotation.SuppressLint
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.core.view.WindowCompat
import com.mcruz.vibestation5.ui.VibeStationApp

@SuppressLint("RestrictedApi")
class MainActivity : ComponentActivity() {
    private val model: RuntimeViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = false
        WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightNavigationBars = false
        if (intent.getBooleanExtra(EXTRA_LAUNCH_DREAMING_SARAH_MENU, false)) {
            model.launchDreamingSarah()
        }
        setContent { VibeStationApp(model) }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        if (event.keyCode == KeyEvent.KEYCODE_BACK && !model.state.guestActive) {
            super.dispatchKeyEvent(event)
        } else {
            model.input.handleKeyEvent(event) || super.dispatchKeyEvent(event)
        }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean =
        model.input.handleMotionEvent(event) || super.dispatchGenericMotionEvent(event)

    private companion object {
        const val EXTRA_LAUNCH_DREAMING_SARAH_MENU = "launch_dreaming_sarah_menu"
    }
}
