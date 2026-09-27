import AVFoundation

/// Decoded audio held in memory as deinterleaved float samples.
struct AudioClip: Sendable {
    var channels: [[Float]]
    var sampleRate: Double

    var frameCount: Int { channels.first?.count ?? 0 }
    var channelCount: Int { channels.count }
    var duration: Double { Double(frameCount) / sampleRate }

    func frames(forMilliseconds ms: Int) -> Int {
        Int(Double(ms) / 1000 * sampleRate)
    }

    func makeBuffer(_ range: Range<Int>) -> AVAudioPCMBuffer? {
        guard !range.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)),
              let destination = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(range.count)
        for c in 0..<channelCount {
            channels[c].withUnsafeBufferPointer { source in
                destination[c].update(from: source.baseAddress! + range.lowerBound, count: range.count)
            }
        }
        return buffer
    }

    /// Matches another clip's format: mixes or duplicates channels, then resamples.
    func conformed(sampleRate target: Double, channelCount targetChannels: Int) -> AudioClip {
        var mixed = channels
        if targetChannels == 1 && channels.count > 1 {
            let scale = 1 / Float(channels.count)
            mixed = [(0..<frameCount).map { i in channels.reduce(0) { $0 + $1[i] } * scale }]
        } else if targetChannels == 2 && channels.count == 1 {
            mixed = [channels[0], channels[0]]
        }
        let clip = AudioClip(channels: mixed, sampleRate: sampleRate)
        guard target != sampleRate, frameCount > 0,
              let input = clip.makeBuffer(0..<clip.frameCount),
              let format = AVAudioFormat(standardFormatWithSampleRate: target, channels: AVAudioChannelCount(mixed.count)),
              let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(frameCount) * target / sampleRate) + 1024)
        else { return clip }
        var consumed = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard let data = output.floatChannelData else { return clip }
        let count = Int(output.frameLength)
        return AudioClip(
            channels: (0..<mixed.count).map { Array(UnsafeBufferPointer(start: data[$0], count: count)) },
            sampleRate: target
        )
    }

    /// Writes a 32-bit float WAV (lossless intermediate for ffmpeg and library copies).
    func writeWAV(to url: URL, range: Range<Int>) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 18
        var start = range.lowerBound
        while start < range.upperBound {
            let end = min(start + chunk, range.upperBound)
            guard let buffer = makeBuffer(start..<end) else { break }
            try file.write(from: buffer)
            start = end
        }
    }
}

enum AudioDecoder {
    /// Decodes with AVFoundation, falling back to ffmpeg for formats Core Audio can't read (ogg, webm, opus).
    static func load(_ url: URL) async throws -> AudioClip {
        try await Task.detached(priority: .userInitiated) {
            do {
                return try decodeNative(url)
            } catch {
                guard let ffmpeg = Tools.ffmpeg else { throw error }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("wav")
                defer { try? FileManager.default.removeItem(at: temp) }
                let log = LogTail()
                let status = try await ProcessRunner().run(
                    ffmpeg,
                    ["-y", "-v", "error", "-i", url.path, "-vn", "-c:a", "pcm_f32le", temp.path],
                    onLine: { log.append($0) }
                )
                guard status == 0 else {
                    throw ToolError.failed("Could not decode \(url.lastPathComponent)\n\(log.text)")
                }
                return try decodeNative(temp)
            }
        }.value
    }

    private static func decodeNative(_ url: URL) throws -> AudioClip {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channelCount = min(Int(format.channelCount), 2)
        let chunk: AVAudioFrameCount = 1 << 18
        guard channelCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw ToolError.failed("Unsupported audio format")
        }

        var channels = Array(repeating: [Float](), count: channelCount)
        for c in 0..<channelCount { channels[c].reserveCapacity(Int(file.length)) }

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            for c in 0..<channelCount {
                channels[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: count))
            }
        }

        guard !channels[0].isEmpty else { throw ToolError.failed("File contains no audio") }
        return AudioClip(channels: channels, sampleRate: format.sampleRate)
    }
}
