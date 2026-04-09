import Cocoa
import SwiftUI

final class AppState {

    // MARK: - State

    var stage: PipelineStage = .idle
    var isRecording = false
    var statusText = "Ready"
    var asrText = ""
    var gptText = ""
    var postprocessEnabled = true
    var translationLanguage: String? = nil

    /// Called when isRecording changes (for menu bar icon update).
    var onRecordingChanged: ((Bool) -> Void)?

    // MARK: - Private

    private let config = SuperVibeConfig()
    private var pipelineClient: PipelineClient?
    private let audioRecorder = AudioRecorder()
    private let hotkeyManager = HotkeyManager()
    private var overlayPanel: OverlayPanel?
    private var pipelineTask: Task<Void, Never>?
    private var asrAccum = ""
    private var gptAccum = ""

    // MARK: - Hotkeys (called after accessibility permission granted)

    func setupHotkeys() {
        hotkeyManager.onToggleRecord = { [weak self] in
            DispatchQueue.main.async { self?.toggleRecording() }
        }
        hotkeyManager.start()
    }

    // MARK: - Toggle

    func toggleRecording() {
        log("[AppState] toggleRecording – isRecording=\(isRecording)")
        if isRecording { stopRecording() } else { startRecording() }
    }

    // MARK: - Start

    func startRecording() {
        guard stage == .idle else {
            log("[AppState] startRecording skipped, stage=\(stage)")
            return
        }

        asrText = ""; gptText = ""
        asrAccum = ""; gptAccum = ""
        stage = .recording
        isRecording = true
        statusText = "Recording..."
        onRecordingChanged?(true)
        log("[AppState] Recording started – postprocess=\(postprocessEnabled) translation=\(translationLanguage ?? "off")")

        showOverlay()

        audioRecorder.onAudioChunk = { [weak self] chunk in
            self?.pipelineClient?.sendAudioChunk(chunk)
        }

        do {
            try audioRecorder.start()
        } catch {
            stage = .error; isRecording = false
            statusText = "Mic error: \(error.localizedDescription)"
            onRecordingChanged?(false)
            log("[AppState] Mic error: \(error)")
            updateOverlay()
            return
        }

        pipelineTask = Task { [weak self] in await self?.runPipeline() }
    }

    // MARK: - Stop

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        onRecordingChanged?(false)
        audioRecorder.stop()
        pipelineClient?.stopSession()
        log("[AppState] Recording stopped, sending stop to pipeline")

        if stage == .recording {
            stage = .recognizing
            statusText = "Transcribing..."
            updateOverlay()
        }
    }

    // MARK: - Pipeline

    private func runPipeline() async {
        let client = PipelineClient(url: config.pipelineURL, timeout: config.pipelineTimeout)
        pipelineClient = client
        setupCallbacks(client)

        do {
            log("[Pipeline] Connecting to \(config.pipelineURL)...")
            try await client.connect(
                clientVersion: config.clientVersion,
                deviceId: config.deviceId
            )

            var innerConfig: [String: Any] = [
                "sample_rate": 16000,
                "channels": 1,
                "platform": "macOS",
            ]
            if let lang = translationLanguage {
                innerConfig["target_language"] = lang
            }
            let cfg: [String: Any] = [
                "type": "start",
                "config": innerConfig,
            ]
            log("[Pipeline] startSession config: \(cfg)")

            try await client.startSession(config: cfg)
            await client.receiveUntilDone()
        } catch {
            log("[Pipeline] ERROR: \(error)")
            DispatchQueue.main.async {
                self.stage = .error
                self.statusText = "Pipeline error: \(error.localizedDescription)"
                self.updateOverlay()
            }
        }

        client.close()
        pipelineClient = nil
        log("[Pipeline] Closed")
    }

    private func setupCallbacks(_ client: PipelineClient) {
        client.onASRDelta = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                self.asrAccum += text
                self.asrText = self.asrAccum
                if self.stage == .recording || self.stage == .recognizing {
                    self.stage = .recognizing
                }
                self.updateOverlay()
            }
        }
        client.onASRDone = { [weak self] text, elapsed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.asrText = text
                self.stage = self.postprocessEnabled ? .polishing : .done
                self.statusText = self.postprocessEnabled ? "Polishing..." : "Done"
                self.updateOverlay()
                log("[ASR] \(String(format: "%.1f", elapsed))s – \(text.prefix(80))")
            }
        }
        client.onGPTDelta = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gptAccum += text
                self.gptText = self.gptAccum
                self.updateOverlay()
            }
        }
        client.onGPTDone = { [weak self] text, elapsed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gptText = text
                self.updateOverlay()
                log("[GPT] \(String(format: "%.1f", elapsed))s – \(text.prefix(80))")
            }
        }
        client.onError = { [weak self] error in
            DispatchQueue.main.async {
                log("[Pipeline] onError: \(error)")
                self?.stage = .error
                self?.statusText = "Error: \(error)"
                self?.updateOverlay()
            }
        }
        client.onDone = { [weak self] elapsed in
            DispatchQueue.main.async {
                log("[Pipeline] onDone elapsed=\(elapsed)")
                self?.finishSession()
            }
        }
    }

    // MARK: - Finish

    private func finishSession() {
        stage = .done
        let finalText = gptText.isEmpty ? asrText : gptText
        statusText = "Done"
        updateOverlay()
        log("[AppState] Finish – text=\"\(finalText.prefix(80))\"")

        guard !finalText.isEmpty else {
            scheduleReset(delay: 1.0)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            PasteService.paste(finalText)
        }
        scheduleReset(delay: 1.5)
    }

    private static func languageName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "zh": return "Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "es": return "Spanish"
        case "de": return "German"
        default:   return code
        }
    }

    private func scheduleReset(delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.hideOverlay()
            self?.stage = .idle
            self?.statusText = "Ready"
        }
    }

    // MARK: - Overlay

    private func showOverlay() {
        if overlayPanel == nil { overlayPanel = OverlayPanel() }
        updateOverlay()
        overlayPanel?.positionCenter()
        overlayPanel?.orderFront(nil)
    }

    private func updateOverlay() {
        overlayPanel?.contentView = NSHostingView(rootView: OverlayContentView(
            stage: stage, asrText: asrText, gptText: gptText,
            isTranslation: translationLanguage != nil
        ))
    }

    private func hideOverlay() {
        overlayPanel?.orderOut(nil)
        overlayPanel?.contentView = nil
    }
}
