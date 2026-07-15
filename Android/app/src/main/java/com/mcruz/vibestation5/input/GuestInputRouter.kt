// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5.input

import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import kotlin.math.abs

enum class GuestAction {
    Up,
    Down,
    Left,
    Right,
    Confirm,
    Back,
    Options,
}

class GuestInputRouter(private val actionHandler: (GuestAction) -> Unit) {
    var statusHandler: ((String) -> Unit)? = null
    private var lastAxisActionAt = 0L

    fun handleKeyEvent(event: KeyEvent): Boolean {
        val action = actionForKey(event.keyCode) ?: return false
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            actionHandler(action)
            val device = event.device
            statusHandler?.invoke(if (device != null && device.sources and InputDevice.SOURCE_GAMEPAD != 0) {
                device.name ?: "Android gamepad"
            } else {
                "Android keyboard"
            })
        }
        return true
    }

    fun handleMotionEvent(event: MotionEvent): Boolean {
        if (event.action != MotionEvent.ACTION_MOVE ||
            event.source and (InputDevice.SOURCE_JOYSTICK or InputDevice.SOURCE_GAMEPAD) == 0
        ) return false
        val now = event.eventTime
        if (now - lastAxisActionAt < 180) return true
        val x = event.getAxisValue(MotionEvent.AXIS_X)
        val y = event.getAxisValue(MotionEvent.AXIS_Y)
        val action = when {
            abs(y) >= abs(x) && y < -0.65f -> GuestAction.Up
            abs(y) >= abs(x) && y > 0.65f -> GuestAction.Down
            x < -0.65f -> GuestAction.Left
            x > 0.65f -> GuestAction.Right
            else -> null
        }
        if (action != null) {
            lastAxisActionAt = now
            actionHandler(action)
            statusHandler?.invoke(event.device?.name ?: "Android gamepad")
        }
        return true
    }

    fun touch(action: GuestAction) {
        actionHandler(action)
        statusHandler?.invoke("Touch controls")
    }

    private fun actionForKey(keyCode: Int): GuestAction? = when (keyCode) {
        KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_W -> GuestAction.Up
        KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_S -> GuestAction.Down
        KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_A -> GuestAction.Left
        KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_D -> GuestAction.Right
        KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_SPACE -> GuestAction.Confirm
        KeyEvent.KEYCODE_BUTTON_B, KeyEvent.KEYCODE_ESCAPE, KeyEvent.KEYCODE_BACK -> GuestAction.Back
        KeyEvent.KEYCODE_BUTTON_START, KeyEvent.KEYCODE_MENU -> GuestAction.Options
        else -> null
    }
}
