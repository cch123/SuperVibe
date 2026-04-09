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
    private var sessionTranslate = false

    /// Called when isRecording changes (for menu bar icon update).
    var onRecordingChanged: ((Bool) -> Void)?

    // MARK: - Private

    private let config = SuperVibeConfig()
    private var pipelineClient: PipelineClient?
    private let audioRecorder = AudioRecorder()
    private let hotkeyManager = HotkeyManager()
    private var overlayPanel: OverlayPanel?
    private let overlayVM = OverlayViewModel()
    private var pipelineTask: Task<Void, Never>?
    private var asrAccum = ""
    private var gptAccum = ""

    // MARK: - Hotkeys

    func setupHotkeys() {
        hotkeyManager.onToggleRecord = { [weak self] in
            DispatchQueue.main.async { self?.toggleRecording() }
        }
        hotkeyManager.onToggleTranslate = { [weak self] in
            DispatchQueue.main.async { self?.toggleTranslateRecording() }
        }
        hotkeyManager.onCancel = { [weak self] in
            DispatchQueue.main.async { self?.cancelSession() }
        }
        hotkeyManager.start()
    }

    // MARK: - Toggle

    func toggleRecording() {
        log("[AppState] toggleRecording – isRecording=\(isRecording)")
        if isRecording { stopRecording() } else { startRecording(translate: false) }
    }

    func toggleTranslateRecording() {
        log("[AppState] toggleTranslateRecording – isRecording=\(isRecording)")
        if isRecording {
            stopRecording()
        } else if translationLanguage != nil {
            startRecording(translate: true)
        } else {
            log("[AppState] No translation language set, ignoring translate toggle")
        }
    }

    // MARK: - Start

    func startRecording(translate: Bool) {
        guard stage == .idle else {
            log("[AppState] startRecording skipped, stage=\(stage)")
            return
        }

        sessionTranslate = translate
        asrText = ""; gptText = ""
        asrAccum = ""; gptAccum = ""
        stage = .recording
        isRecording = true
        statusText = "Recording..."
        onRecordingChanged?(true)
        log("[AppState] Recording started – mode=\(translate ? "translate(\(translationLanguage ?? "?"))" : "transcribe")")

        overlayVM.isTranslation = sessionTranslate
        setOverlayStage(.recording)
        showOverlay()
        overlayVM.startSmoothing()

        // Audio chunk forwarding
        audioRecorder.onAudioChunk = { [weak self] chunk in
            self?.pipelineClient?.sendAudioChunk(chunk)
        }
        // Audio level for waveform
        audioRecorder.onAudioLevel = { [weak self] level in
            self?.overlayVM.pushLevel(level)
        }

        do {
            try audioRecorder.start()
        } catch {
            stage = .error; isRecording = false
            statusText = "Mic error: \(error.localizedDescription)"
            onRecordingChanged?(false)
            setOverlayStage(.error)
            log("[AppState] Mic error: \(error)")
            return
        }

        pipelineTask = Task { [weak self] in await self?.runPipeline() }
    }

    // MARK: - Cancel (ESC)

    func cancelSession() {
        guard stage != .idle else { return }
        log("[AppState] Session cancelled (ESC)")
        // Reset stage FIRST so async callbacks are ignored
        stage = .idle
        statusText = "Ready"
        if isRecording {
            isRecording = false
            onRecordingChanged?(false)
            overlayVM.stopSmoothing()
            audioRecorder.stop()
        }
        // Clear callbacks before closing so no late error fires
        pipelineClient?.onError = nil
        pipelineClient?.onDone = nil
        pipelineClient?.onASRDelta = nil
        pipelineClient?.onASRDone = nil
        pipelineClient?.onGPTDelta = nil
        pipelineClient?.onGPTDone = nil
        pipelineClient?.close()
        pipelineClient = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        hideOverlay()
    }

    // MARK: - Stop

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        onRecordingChanged?(false)
        overlayVM.stopSmoothing()
        audioRecorder.stop()
        pipelineClient?.stopSession()
        log("[AppState] Recording stopped, sending stop to pipeline")

        if stage == .recording {
            stage = .recognizing
            statusText = "Transcribing..."
            setOverlayStage(.recognizing)
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
            if sessionTranslate, let lang = translationLanguage {
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
                self.setOverlayStage(.error)
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
                    self.setOverlayStage(.recognizing, asr: self.asrText)
                }
            }
        }
        client.onASRDone = { [weak self] text, elapsed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.asrText = text
                log("[ASR] \(String(format: "%.1f", elapsed))s – \(text.prefix(80))")

                if self.sessionTranslate && self.translationLanguage != nil {
                    self.stage = .translating
                    self.statusText = "Translating..."
                    self.setOverlayStage(.translating)
                } else {
                    // No translation — ASR is the final result
                    self.stage = .done
                    self.statusText = "Done"
                }
            }
        }
        client.onGPTDelta = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gptAccum += text
                self.gptText = self.gptAccum
                self.setOverlayStage(self.stage, asr: self.asrText, gpt: self.gptText)
            }
        }
        client.onGPTDone = { [weak self] text, elapsed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gptText = text
                self.setOverlayStage(self.stage, asr: self.asrText, gpt: self.gptText)
                log("[GPT] \(String(format: "%.1f", elapsed))s – \(text.prefix(80))")
            }
        }
        client.onError = { [weak self] error in
            DispatchQueue.main.async {
                log("[Pipeline] onError: \(error)")
                self?.stage = .error
                self?.statusText = "Error: \(error)"
                self?.setOverlayStage(.error)
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

    /// Strip trailing period/。 for short single-sentence results.
    private func trimTrailingPunctuation(_ text: String) -> String {
        var s = text
        // Only strip if it looks like a single sentence (no mid-sentence punctuation)
        let midPunct: [Character] = [".", "。", "!", "！", "?", "？"]
        let body = s.dropLast()
        let hasMidPunct = body.contains(where: { midPunct.contains($0) })
        if !hasMidPunct, let last = s.last, last == "." || last == "。" {
            s.removeLast()
        }
        return s
    }

    private func finishSession() {
        stage = .done
        let raw = gptText.isEmpty ? asrText : gptText
        let finalText = trimTrailingPunctuation(raw)
        statusText = "Done"
        setOverlayStage(.done, asr: asrText, gpt: gptText)
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

    private func scheduleReset(delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.hideOverlay()
            self?.stage = .idle
            self?.statusText = "Ready"
        }
    }

    // MARK: - Overlay

    private func setOverlayStage(
        _ stage: PipelineStage,
        asr: String = "",
        gpt: String = ""
    ) {
        overlayVM.stage = stage
        overlayVM.asrText = asr
        overlayVM.gptText = gpt
        overlayVM.isTranslation = sessionTranslate
    }

    private func showOverlay() {
        if overlayPanel == nil {
            overlayVM.onCancel = { [weak self] in self?.cancelSession() }
            overlayVM.onConfirm = { [weak self] in self?.stopRecording() }
            overlayPanel = OverlayPanel()
            overlayPanel?.contentView = NSHostingView(
                rootView: OverlayRootView(vm: overlayVM)
            )
        }
        overlayPanel?.positionCenter()
        overlayPanel?.orderFront(nil)
    }

    private func hideOverlay() {
        overlayPanel?.orderOut(nil)
    }
}
