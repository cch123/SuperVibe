import AVFoundation
import Foundation

final class AudioRecorder {

    var onAudioChunk: ((Data) -> Void)?

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

        dataLock.lock()
        accumulatedPCM.append(pcmData)
        dataLock.unlock()

        onAudioChunk?(pcmData)
    }

    // MARK: - Error

    enum RecorderError: LocalizedError {
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device available"
            }
        }
    }
}
