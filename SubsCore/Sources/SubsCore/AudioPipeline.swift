import Foundation

/// What to put on the socket.
public enum Outgoing: Equatable, Sendable {
    /// 16-bit little-endian mono PCM at `Soniox.sampleRate`.
    case audio(Data)
    /// Ask the server to finalize what it heard (sent once when the sound stops).
    case finalize
}

/// Collects captured samples into ~100 ms chunks and sends audio only while the Mac is
/// actually playing sound. Silence is not sent (it would be billed), except for a short tail
/// after the sound stops, followed by one `finalize` so the last words appear right away.
public struct AudioPipeline: Sendable {
    public var chunkSamples: Int
    /// A chunk at or above this level opens the gate.
    public var openThresholdDB: Float
    /// Keep sending this long after the last loud chunk (covers pauses between words).
    public var hangover: TimeInterval

    public private(set) var isOpen = false
    private var buffer: [Int16] = []
    private var lastLoud: Date?
    /// The most recent quiet chunk, sent first when the gate opens so word onsets aren't cut.
    private var preroll: Data?

    public init(chunkSamples: Int = Soniox.sampleRate / 10, openThresholdDB: Float = -55,
                hangover: TimeInterval = 1.5) {
        self.chunkSamples = chunkSamples
        self.openThresholdDB = openThresholdDB
        self.hangover = hangover
    }

    public mutating func append(_ samples: [Int16], at now: Date) -> [Outgoing] {
        buffer.append(contentsOf: samples)
        var out: [Outgoing] = []
        while buffer.count >= chunkSamples {
            let chunk = Array(buffer.prefix(chunkSamples))
            buffer.removeFirst(chunkSamples)
            out.append(contentsOf: process(chunk, at: now))
        }
        return out
    }

    /// Forget buffered audio and close the gate (e.g. after a reconnect).
    public mutating func reset() {
        buffer.removeAll()
        isOpen = false
        lastLoud = nil
        preroll = nil
    }

    private mutating func process(_ chunk: [Int16], at now: Date) -> [Outgoing] {
        let data = PCM.littleEndianData(chunk)
        let loud = PCM.levelDB(chunk) >= openThresholdDB
        if loud { lastLoud = now }

        if isOpen {
            if loud || (lastLoud.map { now.timeIntervalSince($0) < hangover } ?? false) {
                return [.audio(data)]
            }
            isOpen = false
            preroll = nil  // this chunk is sent now; don't send it twice
            return [.audio(data), .finalize]
        }

        if loud {
            isOpen = true
            var out: [Outgoing] = []
            if let preroll { out.append(.audio(preroll)) }
            preroll = nil
            out.append(.audio(data))
            return out
        }
        preroll = data
        return []
    }
}

public enum PCM {
    /// RMS level in dBFS (-120 for digital silence).
    public static func levelDB(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Double = 0
        for s in samples {
            let v = Double(s) / 32768
            sum += v * v
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return -120 }
        return max(-120, Float(20 * log10(rms)))
    }

    public static func littleEndianData(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let v = UInt16(bitPattern: s.littleEndian)
            data.append(UInt8(truncatingIfNeeded: v))
            data.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        return data
    }

    public static func int16(_ value: Float) -> Int16 {
        let clamped = max(-1, min(1, value.isFinite ? value : 0))
        return Int16((clamped * 32767).rounded())
    }
}

/// Mixes captured float audio down to mono and resamples it to the target rate.
/// Stateful across buffers so there are no clicks at buffer boundaries.
public struct MonoResampler: Sendable {
    public let targetRate: Double
    private var sourceRate: Double = 0
    /// Position of the next output sample, in source samples relative to the start of the
    /// next input buffer (may be negative: between `previous` and the first new sample).
    private var position: Double = 0
    private var previous: Float = 0

    public init(targetRate: Double = Double(Soniox.sampleRate)) {
        self.targetRate = targetRate
    }

    /// `channels` holds one array per channel (all the same length).
    public mutating func process(channels: [[Float]], sourceRate: Double) -> [Int16] {
        guard let first = channels.first, !first.isEmpty, sourceRate > 0 else { return [] }
        let count = first.count
        var mono = [Float](repeating: 0, count: count)
        for channel in channels {
            for i in 0..<min(count, channel.count) { mono[i] += channel[i] }
        }
        if channels.count > 1 {
            let scale = 1 / Float(channels.count)
            for i in 0..<count { mono[i] *= scale }
        }

        if sourceRate == targetRate {
            return mono.map(PCM.int16)
        }
        if sourceRate != self.sourceRate {
            self.sourceRate = sourceRate
            position = 0
            previous = mono[0]
        }

        let step = sourceRate / targetRate
        var out: [Int16] = []
        out.reserveCapacity(Int(Double(count) / step) + 1)
        // Sample at index -1 is `previous` (last sample of the previous buffer).
        while position < Double(count - 1) {
            let i = Int(position.rounded(.down))
            let frac = Float(position - Double(i))
            let a = i < 0 ? previous : mono[i]
            let b = mono[i + 1]
            if step >= 2 {
                // Downsampling: average the samples this output covers (cheap anti-aliasing).
                let lo = max(0, i - Int(step / 2))
                let hi = min(count - 1, i + Int(step / 2))
                var sum: Float = 0
                for j in lo...hi { sum += mono[j] }
                out.append(PCM.int16(sum / Float(hi - lo + 1)))
            } else {
                out.append(PCM.int16(a + (b - a) * frac))
            }
            position += step
        }
        position -= Double(count)
        previous = mono[count - 1]
        return out
    }
}
