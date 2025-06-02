//
// For licensing see accompanying LICENSE file.
// Copyright (C) 2025 Apple Inc. All Rights Reserved.
//

import AVFoundation
import CoreImage
import Foundation
import SwiftUI

/// Displays a stream of video frames
public struct VideoFrameView: View {
    @Environment(\.colorScheme) private var colorScheme

    public let frames: AsyncStream<CVImageBuffer>
    public let cameraType: CameraType
    public let action: ((CVImageBuffer) -> Void)?

    @State private var hold: Bool = false
    @State private var videoFrame: CVImageBuffer?

    private var backgroundColor: Color {
        #if os(iOS)
        return Color(.secondarySystemBackground)
        #elseif os(macOS)
        return Color(.secondarySystemFill)
        #else
        // When in doubt, use these values that I captured to match iOS' secondarySystemBackground
        if colorScheme == .dark {
            return Color(red: 0.11, green: 0.11, blue: 0.12)
        } else {
            return Color(red: 0.95, green: 0.95, blue: 0.97)
        }
        #endif
    }

    public init(
        frames: AsyncStream<CVImageBuffer>,
        cameraType: CameraType,
        action: ((CVImageBuffer) -> Void)?
    ) {
        self.frames = frames
        self.cameraType = cameraType
        self.action = action
    }

    public var body: some View {
        Group {
            if let videoFrame {
                _ImageView(image: videoFrame)
                    .overlay(alignment: .bottom) {
                        if cameraType == .single {
                            Button {
                                tap()
                            } label: {
                                if hold {
                                    Label("Resume", systemImage: "play.fill")
                                } else {
                                    Label("Capture Photo", systemImage: "camera.fill")
                                }
                            }
                            .clipShape(.capsule)
                            .buttonStyle(.borderedProminent)
                            .tint(hold ? .gray : .accentColor)
                            .foregroundColor(.white)
                            .padding()
                        }
                    }
            } else {
                // spinner before the camera comes up
                ProgressView()
                    .controlSize(.large)
            }
        }
        // This ensures that we take up the full 4/3 aspect ratio
        // even if we don't have an image to display
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10.0))
        .task {
            // feed frames to the _ImageView
            if Task.isCancelled {
                return
            }
            print("🖼️ VideoFrameView: Starting to listen for frames...")
            var frameCount = 0
            for await frame in frames {
                if !hold {
                    videoFrame = frame
                    frameCount += 1
                    if frameCount % 30 == 0 {
                        print("🖼️ VideoFrameView: Displayed \(frameCount) frames")
                    }
                } else {
                    print("🖼️ VideoFrameView: Frame skipped (hold=true)")
                }
            }
            print("🖼️ VideoFrameView: Frame stream ended")
        }
        .onChange(of: cameraType) { _, newType in
            // No matter what, when the user switches to .continuous,
            // we need to continue showing updated frames
            if newType == .continuous {
                hold = false
            }
        }
    }

    private func tap() {
        if hold {
            // resume
            hold = false
        } else if let videoFrame {
            hold = true
            if let action {
                action(videoFrame)
            }
        }
    }
}

#if os(iOS)
    /// Internal view to display a CVImageBuffer
    private struct _ImageView: UIViewRepresentable {

        let image: CVImageBuffer
        var gravity = CALayerContentsGravity.resizeAspectFill

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.layer.contentsGravity = gravity
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            // Convert CVImageBuffer to CGImage
            let ciImage = CIImage(cvPixelBuffer: image)
            let context = CIContext()
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                uiView.layer.contents = cgImage
                print("🖼️ _ImageView: Successfully rendered CGImage")
            } else {
                print("⚠️ _ImageView: Failed to create CGImage from CVImageBuffer")
            }
        }
    }
#else
    private struct _ImageView: NSViewRepresentable {

        let image: CVImageBuffer
        var gravity = CALayerContentsGravity.resizeAspectFill

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.contentsGravity = gravity
            return view
        }

        func updateNSView(_ uiView: NSView, context: Context) {
            // Convert CVImageBuffer to CGImage
            let ciImage = CIImage(cvPixelBuffer: image)
            let context = CIContext()
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                uiView.layer?.contents = cgImage
                print("🖼️ _ImageView: Successfully rendered CGImage")
            } else {
                print("⚠️ _ImageView: Failed to create CGImage from CVImageBuffer")
            }
        }
    }
#endif
