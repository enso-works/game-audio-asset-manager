import Foundation

/// Writes loop points into a WAV `smpl` chunk. Godot 4 reads these on import
/// (Loop Mode "Detect From WAV", the default), so the sound loops without extra setup.
enum WAVLoop {
    static func embed(in url: URL, loop: LoopPoints) throws {
        var data = try Data(contentsOf: url)
        guard data.count > 12, ascii(data, 0) == "RIFF", ascii(data, 8) == "WAVE" else {
            throw ToolError.failed("\(url.lastPathComponent) is not a RIFF WAV file")
        }

        var sampleRate: UInt32 = 0
        var blockAlign: UInt16 = 0
        var dataSize: UInt32 = 0
        var offset = 12
        while offset + 8 <= data.count {
            let id = ascii(data, offset)
            let size = Int(u32(data, offset + 4))
            if id == "fmt " {
                sampleRate = u32(data, offset + 12)
                blockAlign = u16(data, offset + 20)
            } else if id == "data" {
                dataSize = UInt32(size)
            }
            offset += 8 + size + (size % 2)
        }
        guard sampleRate > 0, blockAlign > 0 else { throw ToolError.failed("Missing WAV format chunk") }

        let frames = Int(dataSize) / Int(blockAlign)
        let last = max(frames - 1, 0)
        var start = min(max(Int((loop.start * Double(sampleRate)).rounded()), 0), last)
        var end = min(max(Int((loop.end * Double(sampleRate)).rounded()) - 1, start + 1), last)
        // Resampling can shift the file length by a frame; keep whole-file loops on the exact edges.
        if start <= 2 { start = 0 }
        if end >= last - 2 { end = last }

        var chunk = Data()
        chunk.append(contentsOf: Array("smpl".utf8))
        let fields: [UInt32] = [
            60,                               // chunk size: 36 header + 24 per loop
            0, 0,                             // manufacturer, product
            UInt32(1_000_000_000 / sampleRate), // sample period in ns
            60, 0,                            // MIDI unity note, pitch fraction
            0, 0,                             // SMPTE format, offset
            1, 0,                             // loop count, sampler data
            0, 0,                             // loop id, type (forward)
            UInt32(start), UInt32(end),       // loop start, end (inclusive)
            0, 0,                             // fraction, play count (infinite)
        ]
        for value in fields {
            withUnsafeBytes(of: value.littleEndian) { chunk.append(contentsOf: $0) }
        }

        if data.count % 2 == 1 { data.append(0) }
        data.append(chunk)
        let riffSize = UInt32(data.count - 8).littleEndian
        withUnsafeBytes(of: riffSize) { data.replaceSubrange(4..<8, with: $0) }
        try data.write(to: url, options: .atomic)
    }

    private static func ascii(_ data: Data, _ offset: Int) -> String {
        String(decoding: data[data.startIndex + offset..<data.startIndex + offset + 4], as: UTF8.self)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }
}
