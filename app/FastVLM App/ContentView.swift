//
// For licensing see accompanying LICENSE file.
// Copyright (C) 2025 Apple Inc. All Rights Reserved.
//

import AVFoundation
import MLXLMCommon
import SwiftUI
import Video
import UniformTypeIdentifiers

// support swift 6
extension CVImageBuffer: @unchecked @retroactive Sendable {}
extension CMSampleBuffer: @unchecked @retroactive Sendable {}

// delay between frames -- controls the frame rate of the updates
let FRAME_DELAY = Duration.milliseconds(1)

struct ContentView: View {
    @State private var camera = CameraController()
    @State private var model = FastVLMModel()

    /// stream of frames -> VideoFrameView, see distributeVideoFrames
    @State private var framesToDisplay: AsyncStream<CVImageBuffer>?
    @State private var streamID = UUID()
    @State private var isStreamReady = false

    @State private var prompt = "Describe the image in English."
    @State private var promptSuffix = "Output should be brief, about 15 words or less."

    @State private var isShowingInfo: Bool = false
    @State private var isShowingVideoPicker: Bool = false
    @State private var selectedVideoURL: URL?

    @State private var selectedCameraType: CameraType = .continuous
    @State private var isEditingPrompt: Bool = false

    var toolbarItemPlacement: ToolbarItemPlacement {
        var placement: ToolbarItemPlacement = .navigation
        #if os(iOS)
        placement = .topBarLeading
        #endif
        return placement
    }
    
    var statusTextColor : Color {
        return model.evaluationState == .processingPrompt ? .black : .white
    }
    
    var statusBackgroundColor : Color {
        switch model.evaluationState {
        case .idle:
            return .gray
        case .generatingResponse:
            return .green
        case .processingPrompt:
            return .yellow
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10.0) {
                        Picker("Camera Type", selection: $selectedCameraType) {
                            ForEach(CameraType.allCases, id: \.self) { cameraType in
                                Text(cameraType.rawValue.capitalized).tag(cameraType)
                            }
                        }
                        // Prevent macOS from adding a text label for the picker
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .onChange(of: selectedCameraType) { _, newType in
                            // Cancel any in-flight requests when switching modes
                            model.cancel()
                            
                            // Reset stream state
                            isStreamReady = false
                            
                            // Handle camera lifecycle when switching modes
                            if newType == .video {
                                camera.stop()
                            } else {
                                camera.start()
                            }
                        }

                        if selectedCameraType == .video {
                            // Video mode - show video player or file picker
                            VStack {
                                if selectedVideoURL != nil, let framesToDisplay {
                                    VideoFrameView(
                                        frames: framesToDisplay,
                                        cameraType: selectedCameraType,
                                        action: { frame in
                                            processSingleFrame(frame)
                                        })
                                        .aspectRatio(16/9, contentMode: .fit)
                                        #if os(macOS)
                                        .frame(maxWidth: 750)
                                        #endif
                                        .overlay(alignment: .topTrailing) {
                                            Button("Change Video") {
                                                isShowingVideoPicker = true
                                            }
                                            .buttonStyle(.bordered)
                                            .padding()
                                        }
                                } else {
                                    VStack {
                                        Image(systemName: "video.badge.plus")
                                            .font(.largeTitle)
                                            .foregroundColor(.secondary)
                                        Text("Select a video file")
                                            .foregroundColor(.secondary)
                                        Button("Choose Video") {
                                            isShowingVideoPicker = true
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                    .frame(height: 200)
                                }
                            }
                        } else if let framesToDisplay, isStreamReady {
                            VideoFrameView(
                                frames: framesToDisplay,
                                cameraType: selectedCameraType,
                                action: { frame in
                                    processSingleFrame(frame)
                                })
                                .id(streamID)  // Restart when stream changes
                                // Because we're using the AVCaptureSession preset
                                // `.vga640x480`, we can assume this aspect ratio
                                .aspectRatio(4/3, contentMode: .fit)
                                #if os(macOS)
                                .frame(maxWidth: 750)
                                #endif
                                .overlay(alignment: .top) {
                                    if !model.promptTime.isEmpty {
                                        Text("TTFT \(model.promptTime)")
                                            .font(.caption)
                                            .foregroundStyle(.white)
                                            .monospaced()
                                            .padding(.vertical, 4.0)
                                            .padding(.horizontal, 6.0)
                                            .background(alignment: .center) {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(Color.black.opacity(0.6))
                                            }
                                            .padding(.top)
                                    }
                                }
                                #if !os(macOS)
                                .overlay(alignment: .topTrailing) {
                                    CameraControlsView(
                                        backCamera: $camera.backCamera,
                                        device: $camera.device,
                                        devices: $camera.devices)
                                    .padding()
                                }
                                #endif
                                .overlay(alignment: .bottom) {
                                    if selectedCameraType == .continuous {
                                        Group {
                                            if model.evaluationState == .processingPrompt {
                                                HStack {
                                                    ProgressView()
                                                        .tint(self.statusTextColor)
                                                        .controlSize(.small)

                                                    Text(model.evaluationState.rawValue)
                                                }
                                            } else if model.evaluationState == .idle {
                                                HStack(spacing: 6.0) {
                                                    Image(systemName: "clock.fill")
                                                        .font(.caption)

                                                    Text(model.evaluationState.rawValue)
                                                }
                                            }
                                            else {
                                                // I'm manually tweaking the spacing to
                                                // better match the spacing with ProgressView
                                                HStack(spacing: 6.0) {
                                                    Image(systemName: "lightbulb.fill")
                                                        .font(.caption)

                                                    Text(model.evaluationState.rawValue)
                                                }
                                            }
                                        }
                                        .foregroundStyle(self.statusTextColor)
                                        .font(.caption)
                                        .bold()
                                        .padding(.vertical, 6.0)
                                        .padding(.horizontal, 8.0)
                                        .background(self.statusBackgroundColor)
                                        .clipShape(.capsule)
                                        .padding(.bottom)
                                    }
                                }
                                #if os(macOS)
                                .frame(maxWidth: .infinity)
                                .frame(minWidth: 500)
                                .frame(minHeight: 375)
                                #endif
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                promptSections

                Section {
                    if model.output.isEmpty && model.running {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            Text(model.output)
                                .foregroundStyle(isEditingPrompt ? .secondary : .primary)
                                .textSelection(.enabled)
                                #if os(macOS)
                                .font(.headline)
                                .fontWeight(.regular)
                                #endif
                        }
                        .frame(minHeight: 50.0, maxHeight: 200.0)
                    }
                } header: {
                    Text("Response")
                        #if os(macOS)
                        .font(.headline)
                        .padding(.bottom, 2.0)
                        #endif
                }

                #if os(macOS)
                Spacer()
                #endif
            }
            
            #if os(iOS)
            .listSectionSpacing(0)
            #elseif os(macOS)
            .padding()
            #endif
            .task {
                // Only start camera if not in video mode
                if selectedCameraType != .video {
                    camera.start()
                }
            }
            .task {
                await model.load()
            }

            #if !os(macOS)
            .onAppear {
                // Prevent the screen from dimming or sleeping due to inactivity
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                // Resumes normal idle timer behavior
                UIApplication.shared.isIdleTimerDisabled = false
            }
            #endif

            // task to distribute video frames -- this will cancel
            // and restart when the view is on/off screen.  note: it is
            // important that this is here (attached to the VideoFrameView)
            // rather than the outer view because this has the correct lifecycle
            .task {
                if Task.isCancelled {
                    return
                }

                await distributeVideoFrames()
            }
            
            // Restart video distribution when video URL changes
            .task(id: selectedVideoURL) {
                if Task.isCancelled {
                    return
                }
                
                if selectedCameraType == .video && selectedVideoURL != nil {
                    print("🔄 Video URL changed, restarting distribution...")
                    await distributeVideoFrames()
                }
            }

            .navigationTitle("FastVLM")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: toolbarItemPlacement) {
                    Button {
                        isShowingInfo.toggle()
                    }
                    label: {
                        Image(systemName: "info.circle")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    if isEditingPrompt {
                        Button {
                            isEditingPrompt.toggle()
                        }
                        label: {
                            Text("Done")
                                .fontWeight(.bold)
                        }
                    }
                    else {
                        Menu {
                            Button("Describe image") {
                                prompt = "Describe the image in English."
                                promptSuffix = "Output should be brief, about 15 words or less."
                            }
                            Button("Facial expression") {
                                prompt = "What is this person's facial expression?"
                                promptSuffix = "Output only one or two words."
                            }
                            Button("Read text") {
                                prompt = "What is written in this image?"
                                promptSuffix = "Output only the text in the image."
                            }
                            #if !os(macOS)
                            Button("Customize...") {
                                isEditingPrompt.toggle()
                            }
                            #endif
                        } label: { Text("Prompts") }
                    }
                }
            }
            .sheet(isPresented: $isShowingInfo) {
                InfoView()
            }
            .fileImporter(
                isPresented: $isShowingVideoPicker,
                allowedContentTypes: [.movie, .video],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let files):
                    if let fileURL = files.first {
                        print("🎬 Video selected: \(fileURL.lastPathComponent)")
                        selectedVideoURL = fileURL
                    }
                case .failure(let error):
                    print("❌ Error selecting video: \(error)")
                }
            }
        }
    }

    var promptSummary: some View {
        Section("Prompt") {
            VStack(alignment: .leading, spacing: 4.0) {
                let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPrompt.isEmpty {
                    Text(trimmedPrompt)
                        .foregroundStyle(.secondary)
                }

                let trimmedSuffix = promptSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedSuffix.isEmpty {
                    Text(trimmedSuffix)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    var promptForm: some View {
        Group {
            #if os(iOS)
            Section("Prompt") {
                TextEditor(text: $prompt)
                    .frame(minHeight: 38)
            }

            Section("Prompt Suffix") {
                TextEditor(text: $promptSuffix)
                    .frame(minHeight: 38)
            }
            #elseif os(macOS)
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("Prompt")
                            .font(.headline)

                        TextEditor(text: $prompt)
                            .frame(height: 38)
                            .padding(.horizontal, 8.0)
                            .padding(.vertical, 10.0)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(10.0)
                    }

                    VStack(alignment: .leading) {
                        Text("Prompt Suffix")
                            .font(.headline)

                        TextEditor(text: $promptSuffix)
                            .frame(height: 38)
                            .padding(.horizontal, 8.0)
                            .padding(.vertical, 10.0)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(10.0)
                    }
                }
            }
            .padding(.vertical)
            #endif
        }
    }

    var promptSections: some View {
        Group {
            #if os(iOS)
            if isEditingPrompt {
                promptForm
            }
            else {
                promptSummary
            }
            #elseif os(macOS)
            promptForm
            #endif
        }
    }

    func analyzeVideoFrames(_ frames: AsyncStream<CVImageBuffer>) async {
        for await frame in frames {
            let userInput = UserInput(
                prompt: .text("\(prompt) \(promptSuffix)"),
                images: [.ciImage(CIImage(cvPixelBuffer: frame))]
            )
            
            // generate output for a frame and wait for generation to complete
            let t = await model.generate(userInput)
            _ = await t.result

            do {
                try await Task.sleep(for: FRAME_DELAY)
            } catch { return }
        }
    }

    func distributeVideoFrames() async {
        print("🔧 distributeVideoFrames() called, selectedCameraType: \(selectedCameraType)")
        
        // First, completely clear the existing stream
        await MainActor.run {
            self.framesToDisplay = nil
            self.isStreamReady = false
            print("🔧 Cleared old stream")
        }
        
        // Wait a moment to ensure UI updates
        try? await Task.sleep(for: .milliseconds(50))
        
        // Create the streams at the beginning
        let (framesToDisplay, framesToDisplayContinuation) = AsyncStream.makeStream(
            of: CVImageBuffer.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        
        // Update the main actor with the new stream
        await MainActor.run {
            self.framesToDisplay = framesToDisplay
            self.streamID = UUID()  // Force VideoFrameView to restart
            print("🔧 Updated framesToDisplay stream with new ID: \(self.streamID)")
        }
        
        // Small delay to ensure stream is properly connected
        try? await Task.sleep(for: .milliseconds(10))
        
        await MainActor.run {
            self.isStreamReady = true  // Show VideoFrameView with new stream
            print("🔧 Stream is ready for VideoFrameView")
        }

        // Only create analysis stream if in continuous mode
        let (framesToAnalyze, framesToAnalyzeContinuation) = AsyncStream.makeStream(
            of: CVImageBuffer.self,
            bufferingPolicy: .bufferingNewest(1)
        )

        if selectedCameraType == .video, let videoURL = selectedVideoURL {
            print("📹 Starting video frame distribution for: \(videoURL.lastPathComponent)")
            // Video mode - extract frames from video
            await distributeVideoFileFrames(
                framesToDisplayContinuation: framesToDisplayContinuation,
                framesToAnalyzeContinuation: framesToAnalyzeContinuation,
                videoURL: videoURL
            )
        } else {
            print("📷 Starting camera frame distribution")
            // Camera mode - attach a stream to the camera
            let frames = AsyncStream<CMSampleBuffer>(bufferingPolicy: .bufferingNewest(1)) {
                camera.attach(continuation: $0)
            }
            
            // set up structured tasks (important -- this means the child tasks
            // are cancelled when the parent is cancelled)
            async let distributeFrames: () = {
                for await sampleBuffer in frames {
                    if let frame = sampleBuffer.imageBuffer {
                        framesToDisplayContinuation.yield(frame)
                        // Only send frames for analysis in continuous mode
                        if await selectedCameraType == .continuous {
                            framesToAnalyzeContinuation.yield(frame)
                        }
                    }
                }

                // detach from the camera controller and feed to the video view
                await MainActor.run {
                    self.framesToDisplay = nil
                    self.camera.detach()
                }

                framesToDisplayContinuation.finish()
                framesToAnalyzeContinuation.finish()
            }()

            // Only analyze frames if in continuous mode
            if selectedCameraType == .continuous {
                async let analyze: () = analyzeVideoFrames(framesToAnalyze)
                await distributeFrames
                await analyze
            } else {
                await distributeFrames
            }
        }
    }
    
    func distributeVideoFileFrames(
        framesToDisplayContinuation: AsyncStream<CVImageBuffer>.Continuation,
        framesToAnalyzeContinuation: AsyncStream<CVImageBuffer>.Continuation,
        videoURL: URL
    ) async {
        print("🎥 Setting up video asset for: \(videoURL.lastPathComponent)")
        
        // Start accessing security-scoped resource (required for sandboxed apps)
        let accessing = videoURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                videoURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.appliesPreferredTrackTransform = true
        
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            print("❌ Failed to load video tracks")
            framesToDisplayContinuation.finish()
            framesToAnalyzeContinuation.finish()
            return
        }
        
        print("✅ Found video track: \(track)")
        
        do {
            let duration = try await asset.load(.duration)
            let timeRange = try await track.load(.timeRange)
            let frameRate = try await track.load(.nominalFrameRate)
            
            print("✅ Video loaded - Duration: \(CMTimeGetSeconds(duration))s, Frame rate: \(frameRate)fps")
            
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            var currentTime = timeRange.start
            
            // Create analysis stream for continuous analysis
            let (framesToAnalyze, framesToAnalyzeContinuation2) = AsyncStream.makeStream(
                of: CVImageBuffer.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            
            // Start analysis task in parallel
            async let analyze: () = analyzeVideoFrames(framesToAnalyze)
            
            print("🔄 Starting video frame extraction loop...")
            var frameCount = 0
            
            // Extract and distribute frames
            async let extractFrames: () = {
                // Loop the video continuously
                while !Task.isCancelled {
                    if currentTime >= CMTimeAdd(timeRange.start, duration) {
                        currentTime = timeRange.start // Loop back to start
                        print("🔁 Video looped back to start")
                    }
                    
                    do {
                        let (cgImage, _) = try await imageGenerator.image(at: currentTime)
                        
                        // Convert CGImage to CVImageBuffer
                        var pixelBuffer: CVPixelBuffer?
                        let options: [String: Any] = [
                            kCVPixelBufferCGImageCompatibilityKey as String: true,
                            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
                        ]
                        
                        let status = CVPixelBufferCreate(
                            kCFAllocatorDefault,
                            cgImage.width,
                            cgImage.height,
                            kCVPixelFormatType_32BGRA,
                            options as CFDictionary,
                            &pixelBuffer
                        )
                        
                        if status == kCVReturnSuccess, let pixelBuffer = pixelBuffer {
                            CVPixelBufferLockBaseAddress(pixelBuffer, [])
                            let context = CGContext(
                                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                width: cgImage.width,
                                height: cgImage.height,
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                            )
                            
                            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
                            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                            
                            framesToDisplayContinuation.yield(pixelBuffer)
                            framesToAnalyzeContinuation2.yield(pixelBuffer)
                            
                            frameCount += 1
                            if frameCount % 30 == 0 {  // Log every 30 frames
                                print("📊 Processed \(frameCount) frames")
                                print("📺 Yielded frame \(frameCount) to display stream")
                            }
                        } else {
                            print("⚠️ Failed to create pixel buffer, status: \(status)")
                        }
                        
                        currentTime = CMTimeAdd(currentTime, frameDuration)
                        
                        // Control frame rate
                        try await Task.sleep(for: FRAME_DELAY)
                        
                    } catch {
                        print("⚠️ Error extracting frame at time \(CMTimeGetSeconds(currentTime)): \(error)")
                        currentTime = CMTimeAdd(currentTime, frameDuration)
                    }
                }
                
                print("🛑 Video frame extraction stopped")
                
                await MainActor.run {
                    self.framesToDisplay = nil
                }
                
                framesToDisplayContinuation.finish()
                framesToAnalyzeContinuation2.finish()
            }()
            
            await extractFrames
            await analyze
            
        } catch {
            print("❌ Error loading video properties: \(error)")
            framesToDisplayContinuation.finish()
            framesToAnalyzeContinuation.finish()
        }
    }

    /// Perform FastVLM inference on a single frame.
    /// - Parameter frame: The frame to analyze.
    func processSingleFrame(_ frame: CVImageBuffer) {
        // Reset Response UI (show spinner)
        Task { @MainActor in
            model.output = ""
        }

        // Construct request to model
        let userInput = UserInput(
            prompt: .text("\(prompt) \(promptSuffix)"),
            images: [.ciImage(CIImage(cvPixelBuffer: frame))]
        )

        // Post request to FastVLM
        Task {
            await model.generate(userInput)
        }
    }
}

#Preview {
    ContentView()
}
