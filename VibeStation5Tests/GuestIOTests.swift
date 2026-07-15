// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import VibeStation5

final class GuestIOTests: XCTestCase {
    func testPadPacketMatchesScePadDataLayout() {
        let state = GuestInputState(
            buttons: [.cross, .options],
            leftStick: SIMD2(1, 1),
            rightStick: SIMD2(-1, -1),
            leftTrigger: 0.5,
            rightTrigger: 1
        )
        let packet = state.guestPadData(timestampMicroseconds: 0x0102_0304_0506_0708)

        XCTAssertEqual(packet.count, 0x78)
        XCTAssertEqual(readUInt32(packet, 0), 0x4308)
        XCTAssertEqual(packet[0x04], 255)
        XCTAssertEqual(packet[0x05], 1)
        XCTAssertEqual(packet[0x06], 1)
        XCTAssertEqual(packet[0x07], 255)
        XCTAssertEqual(packet[0x08], 128)
        XCTAssertEqual(packet[0x09], 255)
        XCTAssertEqual(readUInt32(packet, 0x18), Float(1).bitPattern)
        XCTAssertEqual(packet[0x4C], 1)
        XCTAssertEqual(readUInt64(packet, 0x50), 0x0102_0304_0506_0708)
        XCTAssertEqual(packet[0x68], 1)
    }

    func testControllerInformationMatchesExpectedPS5Shape() {
        let information = GuestInputState.controllerInformation()
        XCTAssertEqual(information.count, 0x1C)
        XCTAssertEqual(Float(bitPattern: readUInt32(information, 0)), Float(44.86))
        XCTAssertEqual(readUInt16(information, 0x04), 1920)
        XCTAssertEqual(readUInt16(information, 0x06), 943)
        XCTAssertEqual(information[0x08], 30)
        XCTAssertEqual(information[0x09], 30)
        XCTAssertEqual(information[0x0A], 0)
        XCTAssertEqual(information[0x0B], 1)
        XCTAssertEqual(information[0x0C], 1)
    }

    func testMonoS16AudioExpandsToStereoFloat() {
        var pcm = Data()
        append(Int16.min, to: &pcm)
        append(Int16.max, to: &pcm)
        let samples = GuestAudioOutput.stereoFloatSamples(from: GuestAudioBuffer(
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 2,
            isFloat: false,
            data: pcm
        ))

        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], -1, accuracy: 0.0001)
        XCTAssertEqual(samples[1], -1, accuracy: 0.0001)
        XCTAssertEqual(samples[2], Float(Int16.max) / 32_768, accuracy: 0.0001)
        XCTAssertEqual(samples[3], Float(Int16.max) / 32_768, accuracy: 0.0001)
    }

    func testStereoFloatAudioPreservesChannels() {
        var pcm = Data()
        for sample: Float in [0.25, -0.5, 0.75, -1] {
            append(sample.bitPattern, to: &pcm)
        }
        let samples = GuestAudioOutput.stereoFloatSamples(from: GuestAudioBuffer(
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 2,
            isFloat: true,
            data: pcm
        ))

        XCTAssertEqual(samples, [0.25, -0.5, 0.75, -1])
    }

    func testAudioPeakDistinguishesSignalFromSilence() {
        let silence = GuestAudioBuffer(
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 64,
            isFloat: false,
            data: Data(repeating: 0, count: 64 * 2 * 2)
        )
        var signalData = Data()
        for sample in [Int16(0), Int16(8_192), Int16(-16_384), Int16.max] {
            append(sample, to: &signalData)
        }
        let signal = GuestAudioBuffer(
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 2,
            isFloat: false,
            data: signalData
        )

        XCTAssertEqual(GuestAudioOutput.peakMagnitude(from: silence), 0)
        XCTAssertEqual(
            GuestAudioOutput.peakMagnitude(from: signal),
            Float(Int16.max) / 32_768,
            accuracy: 0.0001
        )
    }

    private func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | (UInt32(data[offset + $1]) << UInt32($1 * 8)) }
    }

    private func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | (UInt64(data[offset + $1]) << UInt64($1 * 8)) }
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
