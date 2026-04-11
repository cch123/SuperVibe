import AVFoundation
import Foundation

final class AudioRecorder {

    var onAudioChunk: ((Data) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private var audioEngine: AVAudioEngine?
    private let dataLock = NSLock()
    private var accumulatedPCM = Data()
    private(set) var isRecording = false

    // MARK: - Start

    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let inputRate = inputFormat.sampleRate
        let inputChannels = Int(inputFormat.channelCount)

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.processBuffer(
                buffer,
                inputRate: inputRate,
                inputChannels: inputChannels
            )
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        isRecording = true
        log("[Audio] Recording started (\(inputRate) Hz, \(inputChannels) ch)")
    }

    // MARK: - Stop

    @discardableResult
    func stop() -> Data {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        dataLock.lock()
        let data = accumulatedPCM
        accumulatedPCM = Data()
        dataLock.unlock()

        log("[Audio] Recording stopped (\(data.count) bytes)")
        return data
    }

    // MARK: - Processing

    /// Downsample + convert to 16 kHz mono Int16 PCM.
    private func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        inputRate: Double,
        inputChannels: Int
    ) {
        guard let floatData = buffer.floatChannelData else { return }

        let inputFrames = Int(buffer.frameLength)
        let targetRate = 16000.0
        let ratio = inputRate / targetRate
        let outputFrames = Int(Double(inputFrames) / ratio)
        guard outputFrames > 0 else { return }

        var pcmData = Data(count: outputFrames * MemoryLayout<Int16>.size)
        pcmData.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<outputFrames {
                let srcIndex = min(Int(Double(i) * ratio), inputFrames - 1)
                // Mix down to mono
                var sample: Float = 0
                for ch in 0..<inputChannels {
                    sample += floatData[ch][srcIndex]
                }
                sample /= Float(inputChannels)
                // Clamp & convert to Int16
                let clamped = max(-1.0, min(1.0, sample))
                ptr[i] = Int16(clamped * 32767.0)
            }
        }

        // Compute RMS audio level for visualization
        var sum: Float = 0
        for ch in 0..<inputChannels {
            for i in 0..<inputFrames {
                let s = floatData[ch][i]
                sum += s * s
            }
        }
        let rms = sqrt(sum / Float(inputFrames * inputChannels))
        // dB scale for perceptual loudness mapping
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = (db + 50) / 50  // -50dB..0dB -> 0..1
        let level = max(0, min(1, normalized))
        onAudioLevel?(level)

        dataLock.lock()
        accumulatedPCM.append(pcmData)
        dataLock.unlock()

        onAudioChunk?(pcmData)
    }

    // MARK: - WAV Export

    /// Stop recording and save accumulated PCM data as a 16kHz mono WAV file.
    func stopAndSaveWAV() throws -> URL {
        let pcmData = stop()
        guard !pcmData.isEmpty else {
            throw RecorderError.noAudioData
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervibe-\(UUID().uuidString.prefix(8)).wav")
        try encodeWAV(pcmData: pcmData, sampleRate: 16000, to: wavURL)
        log("[Audio] Saved WAV to \(wavURL.path) (\(pcmData.count) bytes PCM)")
        return wavURL
    }

    private func encodeWAV(pcmData: Data, sampleRate: Int, to url: URL) throws {
        let dataSize = pcmData.count
        let fileSize = 36 + dataSize

        var data = Data()
        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })  // byte rate
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits per sample
        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        data.append(pcmData)

        try data.write(to: url)
    }

    // MARK: - Error

    enum RecorderError: LocalizedError {
        case noInputDevice
        case noAudioData

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device available"
            case .noAudioData:
                return "No audio data recorded"
            }
        }
    }
}
