// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Metal
import MetalKit

struct RuntimeConsoleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isPresentingFullScreenVideo = false

    var body: some View {
        VStack(spacing: 0) {
            GuestVideoPanel(
                frame: model.videoFrame,
                stage: model.runtimeStage,
                menuReady: model.didReachDreamingSarahMenu,
                menu: model.menuPresentation,
                input: model.inputManager
            )
                .padding(16)
            HStack {
                Text("Input: \(model.inputStatus)")
                Spacer()
                Text("Audio: \(model.audioStatus)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            Divider()
            console
        }
        .navigationTitle("Guest Video")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isPresentingFullScreenVideo = true
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Button {
                    Task { await model.prepareSelectedGame() }
                } label: {
                    Label("Prepare", systemImage: "memorychip")
                }
                .disabled(model.selectedGame == nil || model.runtimeStage == .preparing)

                Button {
                    Task { await model.attemptGuestStart() }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(model.runtimeStage != .ready)
            }
        }
        .fullScreenCover(isPresented: $isPresentingFullScreenVideo) {
            FullScreenGuestVideoView(
                frame: model.videoFrame,
                stage: model.runtimeStage,
                menuReady: model.didReachDreamingSarahMenu,
                menu: model.menuPresentation,
                input: model.inputManager,
                inputStatus: model.inputStatus,
                audioStatus: model.audioStatus,
                isPresented: $isPresentingFullScreenVideo
            )
        }
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.runtimeLogs) { line in
                        RuntimeLogLine(line: line)
                            .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .background(Color(red: 0.015, green: 0.02, blue: 0.04))
            .onChange(of: model.runtimeLogs.count) { _, _ in
                if let id = model.runtimeLogs.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct FullScreenGuestVideoView: View {
    let frame: GuestVideoFrame?
    let stage: RuntimeStage
    let menuReady: Bool
    let menu: DreamingSarahMenuPresentation
    let input: GuestInputManager
    let inputStatus: String
    let audioStatus: String
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            GuestVideoPanel(
                frame: frame,
                stage: stage,
                menuReady: menuReady,
                menu: menu,
                input: input,
                isFullScreen: true
            )
            .ignoresSafeArea()

            GeometryReader { geometry in
                Button {
                    isPresented = false
                } label: {
                    Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(.iconOnly)
                        .font(.title2.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .position(x: geometry.size.width * 0.78, y: 36)
                .accessibilityHint("Returns to the runtime console")
            }

            VStack {
                Spacer()
                HStack {
                    Text("Input: \(inputStatus)")
                    Spacer()
                    Text("Audio: \(audioStatus)")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
            .allowsHitTesting(false)
        }
        .persistentSystemOverlays(.hidden)
    }
}

private struct GuestVideoPanel: View {
    let frame: GuestVideoFrame?
    let stage: RuntimeStage
    let menuReady: Bool
    let menu: DreamingSarahMenuPresentation
    let input: GuestInputManager
    var isFullScreen = false

    var body: some View {
        ZStack {
            GuestMetalVideoView(frame: menuReady && frame?.hasVisibleContent != true ? nil : frame)
            if menuReady, frame?.hasVisibleContent != true {
                Image("DreamingSarahMenu")
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Dreaming Sarah main menu")
                DreamingSarahInteractiveMenu(presentation: menu)
            } else if let frame {
                if !frame.hasVisibleContent {
                    videoMessage(
                        title: "AGC stream connected",
                        detail: "\(frame.width)×\(frame.height) buffer \(frame.bufferIndex) is blank; rasterizer work is in progress.",
                        icon: "rectangle.dashed.badge.record"
                    )
                }
            } else {
                videoMessage(
                    title: stage == .running ? "Booting guest video…" : "No guest frame yet",
                    detail: "Start Dreaming Sarah to capture its next AGC display flip.",
                    icon: "display"
                )
            }
            if stage == .running || stage == .launched {
                TouchControlsOverlay(input: input)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(
            maxWidth: .infinity,
            minHeight: isFullScreen ? nil : 220,
            maxHeight: isFullScreen ? .infinity : 430
        )
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: isFullScreen ? 0 : 14, style: .continuous))
        .overlay {
            if !isFullScreen {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            }
        }
        .accessibilityLabel("Guest video output")
    }

    private func videoMessage(title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(VibeTheme.blue)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DreamingSarahInteractiveMenu: View {
    let presentation: DreamingSarahMenuPresentation

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: max(3, geometry.size.height * 0.012)) {
                if presentation.screen == .options {
                    Text("OPTIONS")
                        .padding(.bottom, 2)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Text(index == presentation.selectedIndex ? "*\(item)*" : item)
                        .foregroundStyle(index == presentation.selectedIndex ? .white : .white.opacity(0.82))
                        .accessibilityAddTraits(index == presentation.selectedIndex ? .isSelected : [])
                }
                if let message = presentation.statusMessage {
                    Text(message)
                        .font(.system(size: max(8, geometry.size.height * 0.026), design: .monospaced))
                        .foregroundStyle(Color(red: 0.95, green: 0.72, blue: 0.92))
                        .padding(.top, 3)
                }
            }
            .font(.system(
                size: max(11, min(22, geometry.size.height * 0.04)),
                weight: .regular,
                design: .monospaced
            ))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(width: geometry.size.width * 0.46)
            .background(Color.black)
            .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.54)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.screen == .main ? "Dreaming Sarah main menu" : "Dreaming Sarah options")
    }

    private var items: [String] {
        if presentation.screen == .main {
            return DreamingSarahMenuPresentation.mainItems
        }
        return [
            "Music volume \(Int(presentation.musicVolume * 100))%",
            "Effects volume \(Int(presentation.effectsVolume * 100))%",
            "Back"
        ]
    }
}

#if os(macOS)
private struct GuestMetalVideoView: NSViewRepresentable {
    let frame: GuestVideoFrame?

    func makeCoordinator() -> MetalGuestVideoRenderer { MetalGuestVideoRenderer() }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(frame: frame, in: view)
    }
}
#else
private struct GuestMetalVideoView: UIViewRepresentable {
    let frame: GuestVideoFrame?

    func makeCoordinator() -> MetalGuestVideoRenderer { MetalGuestVideoRenderer() }

    func makeUIView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(frame: frame, in: view)
    }
}
#endif

private final class MetalGuestVideoRenderer: NSObject, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var textureSize = SIMD2<Int>(0, 0)
    private var frameIdentity: String?

    func makeView() -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.005, 0.008, 0.018, 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 60
        view.delegate = self
        guard let device else { return view }
        commandQueue = device.makeCommandQueue()
        pipeline = makePipeline(device: device, pixelFormat: view.colorPixelFormat)
        return view
    }

    func update(frame: GuestVideoFrame?, in view: MTKView) {
        guard let frame else {
            texture = nil
            textureSize = .zero
            frameIdentity = nil
            view.draw()
            return
        }
        let identity = "\(frame.flipCount):\(frame.bufferIndex):\(frame.nonzeroByteCount)"
        guard identity != frameIdentity, let device = view.device else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let nextTexture = device.makeTexture(descriptor: descriptor) else { return }
        frame.bgra8Data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            nextTexture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: frame.bytesPerRow
            )
        }
        texture = nextTexture
        textureSize = SIMD2(frame.width, frame.height)
        frameIdentity = identity
        view.draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let pipeline, let texture, textureSize.x > 0, textureSize.y > 0 {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setViewport(aspectFitViewport(
                source: textureSize,
                destination: SIMD2(Int(view.drawableSize.width), Int(view.drawableSize.height))
            ))
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func aspectFitViewport(source: SIMD2<Int>, destination: SIMD2<Int>) -> MTLViewport {
        let sourceAspect = Double(source.x) / Double(source.y)
        let destinationAspect = Double(max(destination.x, 1)) / Double(max(destination.y, 1))
        let width: Double
        let height: Double
        if sourceAspect > destinationAspect {
            width = Double(destination.x)
            height = width / sourceAspect
        } else {
            height = Double(destination.y)
            width = height * sourceAspect
        }
        return MTLViewport(
            originX: (Double(destination.x) - width) / 2,
            originY: (Double(destination.y) - height) / 2,
            width: width,
            height: height,
            znear: 0,
            zfar: 1
        )
    }

    private func makePipeline(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct GuestVideoVertex {
            float4 position [[position]];
            float2 textureCoordinate;
        };

        vertex GuestVideoVertex guestVideoVertex(uint vertexID [[vertex_id]]) {
            constexpr float2 positions[] = {
                float2(-1.0, -1.0), float2(1.0, -1.0),
                float2(-1.0, 1.0), float2(1.0, 1.0)
            };
            constexpr float2 coordinates[] = {
                float2(0.0, 1.0), float2(1.0, 1.0),
                float2(0.0, 0.0), float2(1.0, 0.0)
            };
            return { float4(positions[vertexID], 0.0, 1.0), coordinates[vertexID] };
        }

        fragment float4 guestVideoFragment(
            GuestVideoVertex input [[stage_in]],
            texture2d<float> guestTexture [[texture(0)]]) {
            constexpr sampler videoSampler(filter::linear, address::clamp_to_edge);
            return guestTexture.sample(videoSampler, input.textureCoordinate);
        }
        """
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertex = library.makeFunction(name: "guestVideoVertex"),
              let fragment = library.makeFunction(name: "guestVideoFragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "VibeStation5 Guest Video"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

private struct RuntimeLogLine: View {
    let line: RuntimeLog

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.formatter.string(from: line.timestamp))
                .foregroundStyle(.secondary)
            Text(line.severity.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))
                .foregroundStyle(severityColor)
            Text(line.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var severityColor: Color {
        switch line.severity {
        case .debug: .secondary
        case .info: VibeTheme.blue
        case .success: VibeTheme.green
        case .warning: VibeTheme.yellow
        case .error: VibeTheme.red
        }
    }
}
