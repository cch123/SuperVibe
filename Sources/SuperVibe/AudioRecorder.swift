import Accelerate
import AVFoundation
import Foundation

/// Captures the default input device and emits mono Int16 PCM at
/// `sampleRate`, plus a normalized level for the waveform display.
final class AudioRecorder {

    /// Called on the audio tap thread with each converted chunk.
    var onAudioChunk: (@Sendable (Data) -> Void)?
    /// Called on the main queue with a 0...1 level per captured buffer.
    var onAudioLevel: ((Float) -> Void)?

    private let sampleRate: Double
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private(set) var isRecording = false

    init(sampleRate: Int) {
        self.sampleRate = Double(sampleRate)
    }

    // MARK: - Start

    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        // AVAudioConverter: resample + mono mix + Int16 conversion. The
        // converter is kept for the whole recording so its resampler state
        // carries across buffers (no discontinuities at buffer boundaries).
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: inputFormat, to: outFmt) else {
            throw RecorderError.converterFailed
        }
        self.converter = conv
        self.outputFormat = outFmt

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            converter = nil
            outputFormat = nil
            throw error
        }
        audioEngine = engine
        isRecording = true
        log("[Audio] Recording started (\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch -> \(Int(sampleRate)) Hz mono)")
    }

    // MARK: - Stop

    func stop() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        converter = nil
        outputFormat = nil
        isRecording = false
        log("[Audio] Recording stopped")
    }

    // MARK: - Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Level meter: RMS via vDSP. Only available for float input, which
        // is what AVAudioEngine input nodes deliver in practice.
        if let floatData = buffer.floatChannelData, let onAudioLevel {
            let channels = Int(buffer.format.channelCount)
            var totalSumSq: Float = 0
            for ch in 0..<channels {
                var chSumSq: Float = 0
                vDSP_svesq(floatData[ch], 1, &chSumSq, vDSP_Length(frameCount))
                totalSumSq += chSumSq
            }
            let rms = sqrt(totalSumSq / Float(frameCount * channels))
            let db = 20 * log10(max(rms, 1e-7))
            let normalized = (db + 50) / 50  // -50dB..0dB -> 0..1
            let level = max(Float(0), min(Float(1), normalized))
            DispatchQueue.main.async { onAudioLevel(level) }
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio) + 16)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if error != nil || outputBuffer.frameLength == 0 { return }

        guard let int16Ptr = outputBuffer.int16ChannelData else { return }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        onAudioChunk?(Data(bytes: int16Ptr[0], count: byteCount))
    }

    // MARK: - Error

    enum RecorderError: LocalizedError {
        case noInputDevice
        case converterFailed

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device available"
            case .converterFailed:
                return "Failed to create audio format converter"
            }
        }
    }
}
