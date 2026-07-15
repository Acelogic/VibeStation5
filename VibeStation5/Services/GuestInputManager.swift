// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GameController

struct GuestPadButtons: OptionSet, Sendable {
    let rawValue: UInt32

    static let l3 = Self(rawValue: 0x0002)
    static let r3 = Self(rawValue: 0x0004)
    static let options = Self(rawValue: 0x0008)
    static let up = Self(rawValue: 0x0010)
    static let right = Self(rawValue: 0x0020)
    static let down = Self(rawValue: 0x0040)
    static let left = Self(rawValue: 0x0080)
    static let l2 = Self(rawValue: 0x0100)
    static let r2 = Self(rawValue: 0x0200)
    static let l1 = Self(rawValue: 0x0400)
    static let r1 = Self(rawValue: 0x0800)
    static let triangle = Self(rawValue: 0x1000)
    static let circle = Self(rawValue: 0x2000)
    static let cross = Self(rawValue: 0x4000)
    static let square = Self(rawValue: 0x8000)
    static let touchpad = Self(rawValue: 0x10_0000)
}

struct GuestInputState: Equatable, Sendable {
    var buttons: GuestPadButtons = []
    var leftStick = SIMD2<Float>(repeating: 0)
    var rightStick = SIMD2<Float>(repeating: 0)
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0

    static let neutral = Self()

    var isNeutral: Bool {
        buttons.isEmpty && leftStick == .zero && rightStick == .zero &&
            leftTrigger == 0 && rightTrigger == 0
    }

    func merged(with other: Self) -> Self {
        func stronger(_ lhs: Float, _ rhs: Float) -> Float {
            abs(rhs) > abs(lhs) ? rhs : lhs
        }
        return Self(
            buttons: buttons.union(other.buttons),
            leftStick: SIMD2(
                stronger(leftStick.x, other.leftStick.x),
                stronger(leftStick.y, other.leftStick.y)
            ),
            rightStick: SIMD2(
                stronger(rightStick.x, other.rightStick.x),
                stronger(rightStick.y, other.rightStick.y)
            ),
            leftTrigger: max(leftTrigger, other.leftTrigger),
            rightTrigger: max(rightTrigger, other.rightTrigger)
        )
    }

    func guestPadData(timestampMicroseconds: UInt64) -> Data {
        var data = Data(repeating: 0, count: 0x78)
        var encodedButtons = buttons
        if leftTrigger > 0.1 { encodedButtons.insert(.l2) }
        if rightTrigger > 0.1 { encodedButtons.insert(.r2) }
        Self.write(encodedButtons.rawValue, to: &data, offset: 0x00)
        data[0x04] = Self.axisByte(leftStick.x)
        data[0x05] = Self.axisByte(-leftStick.y)
        data[0x06] = Self.axisByte(rightStick.x)
        data[0x07] = Self.axisByte(-rightStick.y)
        data[0x08] = Self.triggerByte(leftTrigger)
        data[0x09] = Self.triggerByte(rightTrigger)
        Self.write(Float(1).bitPattern, to: &data, offset: 0x18)
        data[0x4C] = 1
        Self.write(timestampMicroseconds, to: &data, offset: 0x50)
        data[0x68] = 1
        return data
    }

    static func controllerInformation() -> Data {
        var data = Data(repeating: 0, count: 0x1C)
        write(Float(44.86).bitPattern, to: &data, offset: 0x00)
        write(UInt16(1920), to: &data, offset: 0x04)
        write(UInt16(943), to: &data, offset: 0x06)
        data[0x08] = 30
        data[0x09] = 30
        data[0x0A] = 0
        data[0x0B] = 1
        data[0x0C] = 1
        write(UInt32(0), to: &data, offset: 0x10)
        return data
    }

    private static func axisByte(_ value: Float) -> UInt8 {
        UInt8(clamping: Int((max(-1, min(1, value)) * 127 + 128).rounded()))
    }

    private static func triggerByte(_ value: Float) -> UInt8 {
        UInt8(clamping: Int((max(0, min(1, value)) * 255).rounded()))
    }

    private static func write<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data,
        offset: Int
    ) {
        let littleEndian = value.littleEndian
        withUnsafeBytes(of: littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }
}

final class GuestInputManager: @unchecked Sendable {
    private let lock = NSLock()
    private var controllerStates: [ObjectIdentifier: GuestInputState] = [:]
    private var controllerNames: [ObjectIdentifier: String] = [:]
    private var keyboardKeys: Set<GCKeyCode> = []
    private var keyboardConnected = false
    private var touchState = GuestInputState.neutral
    private var notificationTokens: [NSObjectProtocol] = []
    private var statusHandler: (@Sendable (String) -> Void)?
    private var stateHandler: (@Sendable (GuestInputState) -> Void)?

    init() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.configure(controller)
        })
        notificationTokens.append(center.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.remove(controller)
        })
        notificationTokens.append(center.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.configureKeyboard() })
        notificationTokens.append(center.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.lock.withLock {
                self?.keyboardConnected = false
                self?.keyboardKeys.removeAll()
            }
            self?.publishStatus()
        })

        GCController.controllers().forEach(configure)
        configureKeyboard()
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func setStatusHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { statusHandler = handler }
        publishStatus()
    }

    func setStateHandler(_ handler: @escaping @Sendable (GuestInputState) -> Void) {
        lock.withLock { stateHandler = handler }
        publishStatus()
    }

    func snapshot() -> GuestInputState {
        lock.withLock {
            controllerStates.values.reduce(keyboardState().merged(with: touchState)) {
                $0.merged(with: $1)
            }
        }
    }

    func setTouchButton(_ button: GuestPadButtons, pressed: Bool) {
        lock.withLock {
            if pressed {
                touchState.buttons.insert(button)
            } else {
                touchState.buttons.remove(button)
            }
        }
        publishStatus(activity: pressed ? "touch button active" : nil)
    }

    func setTouchLeftStick(_ value: SIMD2<Float>) {
        lock.withLock { touchState.leftStick = value }
        publishStatus(activity: value == .zero ? nil : "left touch stick active")
    }

    func setTouchRightStick(_ value: SIMD2<Float>) {
        lock.withLock { touchState.rightStick = value }
        publishStatus(activity: value == .zero ? nil : "right touch stick active")
    }

    func setTouchTrigger(left: Bool, value: Float) {
        lock.withLock {
            if left { touchState.leftTrigger = value } else { touchState.rightTrigger = value }
        }
        publishStatus(activity: value > 0 ? "touch trigger active" : nil)
    }

    func resetTouch() {
        lock.withLock { touchState = .neutral }
        publishStatus()
    }

    private func configure(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        guard let profile = controller.extendedGamepad else { return }
        lock.withLock {
            controllerNames[identifier] = controller.vendorName ?? "Game controller"
            controllerStates[identifier] = Self.state(from: profile)
        }
        profile.valueChangedHandler = { [weak self, weak controller] profile, _ in
            guard let self, let controller else { return }
            let nextState = Self.state(from: profile)
            self.lock.withLock {
                self.controllerStates[ObjectIdentifier(controller)] = nextState
            }
            self.publishStatus(activity: nextState.isNeutral ? nil : "controller input active")
        }
        publishStatus()
    }

    private func remove(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        lock.withLock {
            controllerStates.removeValue(forKey: identifier)
            controllerNames.removeValue(forKey: identifier)
        }
        publishStatus()
    }

    private func configureKeyboard() {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return }
        lock.withLock { keyboardConnected = true }
        keyboard.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            self?.lock.withLock {
                if pressed {
                    self?.keyboardKeys.insert(keyCode)
                } else {
                    self?.keyboardKeys.remove(keyCode)
                }
            }
            self?.publishStatus(activity: pressed ? "keyboard input active" : nil)
        }
        publishStatus()
    }

    private func keyboardState() -> GuestInputState {
        var state = GuestInputState.neutral
        if keyboardKeys.contains(.upArrow) { state.buttons.insert(.up) }
        if keyboardKeys.contains(.rightArrow) { state.buttons.insert(.right) }
        if keyboardKeys.contains(.downArrow) { state.buttons.insert(.down) }
        if keyboardKeys.contains(.leftArrow) { state.buttons.insert(.left) }

        if keyboardKeys.contains(.keyA) { state.leftStick.x -= 1 }
        if keyboardKeys.contains(.keyD) { state.leftStick.x += 1 }
        if keyboardKeys.contains(.keyW) { state.leftStick.y += 1 }
        if keyboardKeys.contains(.keyS) { state.leftStick.y -= 1 }
        if keyboardKeys.contains(.keyJ) { state.rightStick.x -= 1 }
        if keyboardKeys.contains(.keyL) { state.rightStick.x += 1 }
        if keyboardKeys.contains(.keyI) { state.rightStick.y += 1 }
        if keyboardKeys.contains(.keyK) { state.rightStick.y -= 1 }

        if keyboardKeys.contains(.keyZ) || keyboardKeys.contains(.returnOrEnter) {
            state.buttons.insert(.cross)
        }
        if keyboardKeys.contains(.keyX) || keyboardKeys.contains(.escape) {
            state.buttons.insert(.circle)
        }
        if keyboardKeys.contains(.keyC) { state.buttons.insert(.square) }
        if keyboardKeys.contains(.keyV) { state.buttons.insert(.triangle) }
        if keyboardKeys.contains(.keyQ) { state.buttons.insert(.l1) }
        if keyboardKeys.contains(.keyE) { state.buttons.insert(.r1) }
        if keyboardKeys.contains(.keyR) { state.leftTrigger = 1 }
        if keyboardKeys.contains(.keyF) { state.rightTrigger = 1 }
        if keyboardKeys.contains(.tab) || keyboardKeys.contains(.deleteOrBackspace) {
            state.buttons.insert(.options)
        }
        return state
    }

    private static func state(from profile: GCExtendedGamepad) -> GuestInputState {
        var state = GuestInputState(
            leftStick: SIMD2(profile.leftThumbstick.xAxis.value, profile.leftThumbstick.yAxis.value),
            rightStick: SIMD2(profile.rightThumbstick.xAxis.value, profile.rightThumbstick.yAxis.value),
            leftTrigger: profile.leftTrigger.value,
            rightTrigger: profile.rightTrigger.value
        )
        if profile.dpad.up.isPressed { state.buttons.insert(.up) }
        if profile.dpad.right.isPressed { state.buttons.insert(.right) }
        if profile.dpad.down.isPressed { state.buttons.insert(.down) }
        if profile.dpad.left.isPressed { state.buttons.insert(.left) }
        if profile.buttonA.isPressed { state.buttons.insert(.cross) }
        if profile.buttonB.isPressed { state.buttons.insert(.circle) }
        if profile.buttonX.isPressed { state.buttons.insert(.square) }
        if profile.buttonY.isPressed { state.buttons.insert(.triangle) }
        if profile.leftShoulder.isPressed { state.buttons.insert(.l1) }
        if profile.rightShoulder.isPressed { state.buttons.insert(.r1) }
        if profile.buttonMenu.isPressed { state.buttons.insert(.options) }
        if profile.leftThumbstickButton?.isPressed == true { state.buttons.insert(.l3) }
        if profile.rightThumbstickButton?.isPressed == true { state.buttons.insert(.r3) }
        if let dualSense = profile as? GCDualSenseGamepad,
           dualSense.touchpadButton.isPressed {
            state.buttons.insert(.touchpad)
        }
        return state
    }

    private func publishStatus(activity: String? = nil) {
        let result: (
            String,
            (@Sendable (String) -> Void)?,
            GuestInputState,
            (@Sendable (GuestInputState) -> Void)?
        ) = lock.withLock {
            var components = controllerNames.values.sorted()
            if keyboardConnected { components.append("iPad keyboard") }
            components.append("touch controls")
            var description = components.joined(separator: " + ")
            if let activity { description += " • \(activity)" }
            let state = controllerStates.values.reduce(keyboardState().merged(with: touchState)) {
                $0.merged(with: $1)
            }
            return (description, statusHandler, state, stateHandler)
        }
        result.1?(result.0)
        result.3?(result.2)
    }
}
