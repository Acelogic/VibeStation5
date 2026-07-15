// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation
import Foundation

struct GuestAudioBuffer: Sendable {
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let isFloat: Bool
    let data: Data
}

struct GuestAudioPort: Sendable {
    let handle: UInt64
    let frameCount: Int
    let sampleRate: Double
    let channelCount: Int
    let bytesPerSample: Int
    let isFloat: Bool

    var byteCount: Int { frameCount * channelCount * bytesPerSample }
}

final class GuestAudioPortTable: @unchecked Sendable {
    private let lock = NSLock()
    private var nextHandle: UInt64 = 1
    private var ports: [UInt64: GuestAudioPort] = [:]

    func open(bufferLength: UInt64, frequency: UInt64, format: UInt64) -> GuestAudioPort? {
        guard bufferLength > 0,
              bufferLength <= UInt64(Int.max),
              frequency > 0,
              frequency <= 384_000
        else { return nil }

        let rawFormat = Int(format & 0xFF)
        let channelCount: Int
        switch rawFormat {
        case 0, 3:
            channelCount = 1
        case 1, 4:
            channelCount = 2
        case 2, 5, 6, 7:
            channelCount = 8
        default:
            return nil
        }
        let bytesPerSample = (3...5).contains(rawFormat) || rawFormat == 7 ? 4 : 2

        return lock.withLock {
            let port = GuestAudioPort(
                handle: nextHandle,
                frameCount: Int(bufferLength),
                sampleRate: Double(frequency),
                channelCount: channelCount,
                bytesPerSample: bytesPerSample,
                isFloat: bytesPerSample == 4
            )
            ports[nextHandle] = port
            nextHandle &+= 1
            return port
        }
    }

    func port(for handle: UInt64) -> GuestAudioPort? {
        lock.withLock { ports[handle] }
    }

    @discardableResult
    func close(handle: UInt64) -> Bool {
        lock.withLock { ports.removeValue(forKey: handle) != nil }
    }
}

final class GuestAudioOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mcruz.VibeStation5.guest-audio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outputFormat: AVAudioFormat
    private var isConfigured = false
    private var volume: Float = 1

    init() {
        outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        )!
    }

    func start() {
        queue.async { [self] in
            configureIfNeeded()
            startEngineIfNeeded()
        }
    }

    func enqueue(_ guestBuffer: GuestAudioBuffer) {
        queue.async { [self] in
            configureIfNeeded()
            startEngineIfNeeded()
            let samples = Self.stereoFloatSamples(from: guestBuffer)
            guard !samples.isEmpty,
                  let pcm = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(guestBuffer.frameCount)
                  ),
                  let channels = pcm.floatChannelData
            else { return }

            pcm.frameLength = AVAudioFrameCount(guestBuffer.frameCount)
            for frame in 0..<guestBuffer.frameCount {
                channels[0][frame] = samples[frame * 2]
                channels[1][frame] = samples[frame * 2 + 1]
            }
            player.scheduleBuffer(pcm)
            if !player.isPlaying { player.play() }
        }
    }

    func stop() {
        queue.async { [self] in
            player.stop()
            engine.stop()
#if os(iOS) || os(tvOS)
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
#endif
        }
    }

    func setVolume(_ value: Float) {
        queue.async { [self] in
            volume = max(0, min(1, value))
            player.volume = volume
        }
    }

    static func peakMagnitude(from buffer: GuestAudioBuffer) -> Float {
        guard buffer.frameCount > 0,
              buffer.channelCount > 0,
              !buffer.data.isEmpty
        else { return 0 }

        let bytes = [UInt8](buffer.data)
        let bytesPerSample = buffer.isFloat ? 4 : 2
        let sampleCount = min(
            buffer.frameCount * buffer.channelCount,
            bytes.count / bytesPerSample
        )
        let sampleStride = max(1, sampleCount / 512)
        var peak: Float = 0
        var sampleIndex = 0
        while sampleIndex < sampleCount {
            let offset = sampleIndex * bytesPerSample
            let value: Float
            if buffer.isFloat {
                let bits = UInt32(bytes[offset]) |
                    (UInt32(bytes[offset + 1]) << 8) |
                    (UInt32(bytes[offset + 2]) << 16) |
                    (UInt32(bytes[offset + 3]) << 24)
                let sample = Float(bitPattern: bits)
                value = sample.isFinite ? abs(sample) : 0
            } else {
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                value = abs(Float(Int16(bitPattern: bits)) / 32_768)
            }
            peak = max(peak, value)
            sampleIndex += sampleStride
        }
        return min(1, peak)
    }

    static func stereoFloatSamples(from buffer: GuestAudioBuffer) -> [Float] {
        guard buffer.frameCount > 0,
              buffer.channelCount > 0,
              buffer.data.count >= buffer.frameCount * buffer.channelCount * (buffer.isFloat ? 4 : 2)
        else { return [] }

        let bytes = [UInt8](buffer.data)
        let bytesPerSample = buffer.isFloat ? 4 : 2
        func sample(frame: Int, channel: Int) -> Float {
            let offset = (frame * buffer.channelCount + channel) * bytesPerSample
            if buffer.isFloat {
                let bits = UInt32(bytes[offset]) |
                    (UInt32(bytes[offset + 1]) << 8) |
                    (UInt32(bytes[offset + 2]) << 16) |
                    (UInt32(bytes[offset + 3]) << 24)
                let value = Float(bitPattern: bits)
                return value.isFinite ? value : 0
            }
            let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            return Float(Int16(bitPattern: bits)) / 32_768
        }

        var output = [Float](repeating: 0, count: buffer.frameCount * 2)
        for frame in 0..<buffer.frameCount {
            let left: Float
            let right: Float
            if buffer.channelCount == 1 {
                left = sample(frame: frame, channel: 0)
                right = left
            } else if buffer.channelCount >= 8 {
                let center = sample(frame: frame, channel: 2) * 0.707
                left = sample(frame: frame, channel: 0) + center +
                    sample(frame: frame, channel: 4) * 0.5 +
                    sample(frame: frame, channel: 6) * 0.5
                right = sample(frame: frame, channel: 1) + center +
                    sample(frame: frame, channel: 5) * 0.5 +
                    sample(frame: frame, channel: 7) * 0.5
            } else {
                left = sample(frame: frame, channel: 0)
                right = sample(frame: frame, channel: 1)
            }
            output[frame * 2] = max(-1, min(1, left))
            output[frame * 2 + 1] = max(-1, min(1, right))
        }
        return output
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
#if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(48_000)
        try? session.setActive(true)
#endif
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        player.volume = volume
        isConfigured = true
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
        if !player.isPlaying { player.play() }
    }
}

@MainActor
final class DreamingSarahMenuAudio {
    private var musicPlayer: AVAudioPlayer?
    private var effectPlayers: [String: AVAudioPlayer] = [:]
    private(set) var isMusicPlaying = false
    private(set) var hasMenuMusic = false
    private var musicVolume: Float = 0.7
    private var effectsVolume: Float = 0.9

    func configure(gameRootURL: URL?) {
        stop()
        effectPlayers.removeAll()
        hasMenuMusic = false
        guard let mediaURL = gameRootURL?.appendingPathComponent("media", isDirectory: true) else {
            return
        }

        let musicURL = mediaURL.appendingPathComponent("introtest.flac")
        if let player = try? AVAudioPlayer(contentsOf: musicURL) {
            player.numberOfLoops = -1
            player.volume = musicVolume
            player.prepareToPlay()
            musicPlayer = player
            hasMenuMusic = true
        }

        for name in ["select", "select2", "select_effect", "selectback"] {
            let url = mediaURL.appendingPathComponent("\(name).flac")
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.volume = effectsVolume
            player.prepareToPlay()
            effectPlayers[name] = player
        }
    }

    @discardableResult
    func startMusic() -> Bool {
        guard let musicPlayer else { return false }
        musicPlayer.currentTime = 0
        isMusicPlaying = musicPlayer.play()
        return isMusicPlaying
    }

    func stopMusic() {
        musicPlayer?.stop()
        isMusicPlaying = false
    }

    func playEffect(_ name: String) {
        guard let player = effectPlayers[name] else { return }
        player.currentTime = 0
        player.volume = effectsVolume
        player.play()
    }

    func setMusicVolume(_ value: Float) {
        musicVolume = max(0, min(1, value))
        musicPlayer?.volume = musicVolume
    }

    func setEffectsVolume(_ value: Float) {
        effectsVolume = max(0, min(1, value))
        for player in effectPlayers.values {
            player.volume = effectsVolume
        }
    }

    func stop() {
        musicPlayer?.stop()
        effectPlayers.values.forEach { $0.stop() }
        musicPlayer = nil
        isMusicPlaying = false
    }
}
