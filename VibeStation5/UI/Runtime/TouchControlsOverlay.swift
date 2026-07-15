// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct TouchControlsOverlay: View {
    let input: GuestInputManager

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                TouchPadButton(label: "L2") {
                    input.setTouchTrigger(left: true, value: $0 ? 1 : 0)
                }
                TouchPadButton(label: "L1") {
                    input.setTouchButton(.l1, pressed: $0)
                }
                Spacer()
                TouchPadButton(label: "OPTIONS", compact: false) {
                    input.setTouchButton(.options, pressed: $0)
                }
                Spacer()
                TouchPadButton(label: "R1") {
                    input.setTouchButton(.r1, pressed: $0)
                }
                TouchPadButton(label: "R2") {
                    input.setTouchTrigger(left: false, value: $0 ? 1 : 0)
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                VirtualDPad(input: input)
                VirtualStick(label: "L") { input.setTouchLeftStick($0) }
                Spacer(minLength: 40)
                VirtualStick(label: "R") { input.setTouchRightStick($0) }
                FaceButtons(input: input)
            }
        }
        .padding(12)
        .onDisappear { input.resetTouch() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PlayStation touch controls")
    }
}

private struct VirtualDPad: View {
    let input: GuestInputManager

    var body: some View {
        VStack(spacing: 2) {
            TouchPadButton(systemImage: "triangle.fill", diameter: 36) {
                input.setTouchButton(.up, pressed: $0)
            }
            HStack(spacing: 2) {
                TouchPadButton(systemImage: "triangle.fill", rotation: -90, diameter: 36) {
                    input.setTouchButton(.left, pressed: $0)
                }
                Circle().fill(.white.opacity(0.08)).frame(width: 30, height: 30)
                TouchPadButton(systemImage: "triangle.fill", rotation: 90, diameter: 36) {
                    input.setTouchButton(.right, pressed: $0)
                }
            }
            TouchPadButton(systemImage: "triangle.fill", rotation: 180, diameter: 36) {
                input.setTouchButton(.down, pressed: $0)
            }
        }
    }
}

private struct FaceButtons: View {
    let input: GuestInputManager

    var body: some View {
        VStack(spacing: 2) {
            TouchPadButton(label: "△", diameter: 40) {
                input.setTouchButton(.triangle, pressed: $0)
            }
            HStack(spacing: 32) {
                TouchPadButton(label: "□", diameter: 40) {
                    input.setTouchButton(.square, pressed: $0)
                }
                TouchPadButton(label: "○", diameter: 40) {
                    input.setTouchButton(.circle, pressed: $0)
                }
            }
            TouchPadButton(label: "×", diameter: 40) {
                input.setTouchButton(.cross, pressed: $0)
            }
        }
    }
}

private struct VirtualStick: View {
    let label: String
    let changed: (SIMD2<Float>) -> Void
    @State private var knob = CGSize.zero

    private let diameter: CGFloat = 74
    private let knobDiameter: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.36))
            Circle().strokeBorder(.white.opacity(0.42), lineWidth: 1)
            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: knobDiameter, height: knobDiameter)
                .offset(knob)
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let radius = (diameter - knobDiameter) / 2
                    let vector = CGVector(
                        dx: value.location.x - diameter / 2,
                        dy: value.location.y - diameter / 2
                    )
                    let length = max(1, hypot(vector.dx, vector.dy))
                    let scale = min(1, radius / length)
                    knob = CGSize(width: vector.dx * scale, height: vector.dy * scale)
                    changed(SIMD2(
                        Float(knob.width / radius),
                        Float(-knob.height / radius)
                    ))
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.1)) { knob = .zero }
                    changed(.zero)
                }
        )
        .accessibilityLabel("\(label) analog stick")
    }
}

private struct TouchPadButton: View {
    var label: String?
    var systemImage: String?
    var rotation: Double = 0
    var diameter: CGFloat = 38
    var compact = true
    let changed: (Bool) -> Void
    @State private var pressed = false

    init(
        label: String,
        compact: Bool = true,
        diameter: CGFloat = 38,
        changed: @escaping (Bool) -> Void
    ) {
        self.label = label
        self.compact = compact
        self.diameter = diameter
        self.changed = changed
    }

    init(
        systemImage: String,
        rotation: Double = 0,
        diameter: CGFloat = 38,
        changed: @escaping (Bool) -> Void
    ) {
        self.systemImage = systemImage
        self.rotation = rotation
        self.diameter = diameter
        self.changed = changed
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(pressed ? Color.white.opacity(0.42) : Color.black.opacity(0.36))
            Capsule().strokeBorder(.white.opacity(0.42), lineWidth: 1)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.bold())
                    .rotationEffect(.degrees(rotation))
            } else if let label {
                Text(label)
                    .font(compact ? .caption.bold() : .system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: compact ? diameter : 62, height: diameter)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    changed(true)
                }
                .onEnded { _ in
                    pressed = false
                    changed(false)
                }
        )
        .accessibilityLabel(label ?? "Directional button")
        .accessibilityAddTraits(.isButton)
    }
}
