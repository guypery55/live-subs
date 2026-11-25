import CoreMedia
import Foundation
import ScreenCaptureKit
import SubsCore

/// Captures what the Mac is playing (not the microphone) with ScreenCaptureKit and hands out
/// 16 kHz mono samples. ScreenCaptureKit can't capture audio alone on macOS 13, so it also runs
/// a tiny 2×2, 1 fps video stream whose frames are ignored.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CaptureError: Error { case noDisplay }

    private let queue = DispatchQueue(label: "LiveSubs.audio", qos: .userInitiated)
    private var stream: SCStream?
    /// Only touched on `queue`.
    private var resampler = MonoResampler()
    private let onSamples: @Sendable ([Int16]) -> Void
    private let onStop: @Sendable (Error) -> Void

    init(onSamples: @escaping @Sendable ([Int16]) -> Void, onStop: @escaping @Sendable (Error) -> Void) {
        self.onSamples = onSamples
        self.onStop = onStop
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Soniox.sampleRate
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Registered only so the ignored video frames don't flood the log.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput / SCStreamDelegate (called on `queue` / a system queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let samples = convert(sampleBuffer)
        if !samples.isEmpty { onSamples(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    /// Float32 PCM (interleaved or not, any channel count / rate) → 16 kHz mono Int16.
    private func convert(_ sampleBuffer: CMSampleBuffer) -> [Int16] {
        guard let format = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return [] }
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        var channels: [[Float]] = []
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                if nonInterleaved {
                    for buffer in list {
                        guard let data = buffer.mData else { continue }
                        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        channels.append(Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                                  count: count)))
                    }
                } else if let buffer = list.first, let data = buffer.mData {
                    let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let frames = total / channelCount
                    let p = data.assumingMemoryBound(to: Float.self)
                    channels = (0..<channelCount).map { c in (0..<frames).map { p[$0 * channelCount + c] } }
                }
            }
        } catch {
            return []
        }
        return resampler.process(channels: channels, sourceRate: asbd.mSampleRate)
    }
}
