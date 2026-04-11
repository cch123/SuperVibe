import Cocoa
import SwiftUI

final class AppState: @unchecked Sendable {

    // MARK: - State

    var stage: PipelineStage = .idle
    var isRecording = false
    var statusText = "Ready"
    var asrText = ""
    var gptText = ""
    var polishEnabled: Bool = {
        if let val = AppState.loadConfigValue("polish_enabled") as? Bool {
            return val
        }
        return true  // default ON
    }() {
        didSet { saveConfig() }
    }
    var translationLanguage: String? = AppState.loadConfigValue("translation_language") as? String {
        didSet { saveConfig() }
    }
    private var sessionTranslate = false

    // MARK: - Engine

    var engineMode: EngineMode = {
        if let raw = AppState.loadConfigValue("engine") as? String,
           let mode = EngineMode(rawValue: raw) {
            return mode
        }
        return .cloud
    }() {
        didSet { saveConfig() }
    }

    let vibeVoice = VibeVoiceSTT()
    let llmService = LLMService()
    private(set) var vibeVoiceAvailable = false

    var llmApiKey: String? {
        get { llmService.apiKey }
        set {
            llmService.apiKey = newValue
            saveConfig()
        }
    }

    /// Called when isRecording changes (for menu bar icon update).
    var onRecordingChanged: ((Bool) -> Void)?
    /// Called when engine/config changes (for menu rebuild).
    var onConfigChanged: (() -> Void)?

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

    // MARK: - Init

    init() {
        loadConfig()
    }

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

    // MARK: - Engine Management

    func setEngineMode(_ mode: EngineMode) {
        guard mode != engineMode else { return }
        // Cancel any active session first
        if stage != .idle { cancelSession() }
        engineMode = mode
        log("[AppState] Engine switched to \(mode.rawValue)")

        if mode == .vibeVoice {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                try? self?.vibeVoice.warmup()
            }
        }

        onConfigChanged?()
    }

    func selectVibeModel(_ model: VibeVoiceSTT.Model) {
        vibeVoice.selectModel(model)
        saveConfig()
        log("[AppState] VibeVoice model: \(model.name)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.vibeVoice.warmup()
        }

        onConfigChanged?()
    }

    func checkVibeVoiceAvailability() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let available = self?.vibeVoice.isAvailable() ?? false
            DispatchQueue.main.async {
                self?.vibeVoiceAvailable = available
                self?.onConfigChanged?()
            }
        }
    }

    // MARK: - Toggle

    func toggleRecording() {
        log("[AppState] toggleRecording -- isRecording=\(isRecording)")
        if isRecording { stopRecording() } else { startRecording(translate: false) }
    }

    func toggleTranslateRecording() {
        log("[AppState] toggleTranslateRecording -- isRecording=\(isRecording)")
        if isRecording {
            stopRecording()
        } else if engineMode == .vibeVoice {
            // VibeVoice mode: need LLM API key and translation language
            if translationLanguage != nil && llmService.isAvailable {
                startRecording(translate: true)
            } else if translationLanguage != nil {
                log("[AppState] No LLM API key set, translating without LLM")
                startRecording(translate: true)
            } else {
                log("[AppState] No translation language set")
            }
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
        log("[AppState] Recording started -- mode=\(translate ? "translate(\(translationLanguage ?? "?"))" : "transcribe"), engine=\(engineMode.rawValue)")

        overlayVM.asrText = ""
        overlayVM.gptText = ""
        overlayVM.isTranslation = sessionTranslate
        overlayVM.stage = .recording
        showOverlay()
        overlayVM.startSmoothing()

        // Audio level for waveform (both modes)
        audioRecorder.onAudioLevel = { [weak self] level in
            self?.overlayVM.pushLevel(level)
        }

        if engineMode == .cloud {
            // Cloud mode: stream audio chunks to WebSocket
            audioRecorder.onAudioChunk = { [weak self] chunk in
                self?.pipelineClient?.sendAudioChunk(chunk)
            }
        } else {
            // VibeVoice mode: no streaming, audio accumulates locally
            audioRecorder.onAudioChunk = nil
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

        if engineMode == .cloud {
            pipelineTask = Task { [weak self] in await self?.runPipeline() }
        }
        // VibeVoice: no pipeline task at start, processing happens on stop
    }

    // MARK: - Cancel (ESC)

    func cancelSession() {
        guard stage != .idle else { return }
        log("[AppState] Session cancelled (ESC)")
        stage = .idle
        statusText = "Ready"
        if isRecording {
            isRecording = false
            onRecordingChanged?(false)
            overlayVM.stopSmoothing()
            audioRecorder.stop()
        }
        // Clear cloud pipeline callbacks
        pipelineClient?.onError = nil
        pipelineClient?.onDone = nil
        pipelineClient?.onASRDelta = nil
        pipelineClient?.onASRDone = nil
        pipelineClient?.onGPTDelta = nil
        pipelineClient?.onGPTDone = nil
        pipelineClient?.close()
        pipelineClient = nil
        // Cancel any running task (cloud pipeline or local processing)
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

        if stage == .recording {
            stage = .recognizing
            statusText = "Transcribing..."
            setOverlayStage(.recognizing)
        }

        if engineMode == .cloud {
            audioRecorder.stop()
            pipelineClient?.stopSession()
            log("[AppState] Recording stopped, sending stop to pipeline")
        } else {
            // VibeVoice: save WAV and transcribe locally
            log("[AppState] Recording stopped, starting local transcription")
            pipelineTask = Task { [weak self] in
                await self?.runLocalPipeline()
            }
        }
    }

    // MARK: - Cloud Pipeline

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
            if !polishEnabled {
                innerConfig["skip_gpt"] = true
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
                if self.stage == .recognizing {
                    self.setOverlayStage(.recognizing, asr: self.asrText)
                }
            }
        }
        client.onASRDone = { [weak self] text, elapsed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.asrText = text
                log("[ASR] \(String(format: "%.1f", elapsed))s -- \(text.prefix(80))")

                if self.sessionTranslate && self.translationLanguage != nil {
                    self.stage = .translating
                    self.statusText = "Translating..."
                    self.setOverlayStage(.translating, asr: self.asrText)
                } else if self.polishEnabled {
                    // Polish mode: GPT polish is in progress on the server
                    self.stage = .translating
                    self.statusText = "Polishing..."
                    self.overlayVM.isPolish = true
                    self.setOverlayStage(.translating, asr: self.asrText)
                } else {
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
                log("[GPT] \(String(format: "%.1f", elapsed))s -- \(text.prefix(80))")
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

    // MARK: - Local Pipeline (VibeVoice)

    private func runLocalPipeline() async {
        do {
            let wavURL = try audioRecorder.stopAndSaveWAV()
            defer { try? FileManager.default.removeItem(at: wavURL) }

            log("[VibeVoice] Transcribing \(wavURL.path)...")
            let startTime = Date()
            let text = try vibeVoice.transcribe(wavPath: wavURL.path)
            let asrElapsed = Date().timeIntervalSince(startTime)
            log("[VibeVoice] ASR \(String(format: "%.1f", asrElapsed))s -- \(text.prefix(80))")

            guard !Task.isCancelled, stage != .idle else { return }

            if text.isEmpty {
                log("[VibeVoice] No speech detected")
                await MainActor.run {
                    scheduleReset(delay: 1.0)
                }
                return
            }

            await MainActor.run {
                asrText = text
                asrAccum = text
                setOverlayStage(.recognizing, asr: text)
            }

            // Determine if LLM post-processing is needed
            let needsTranslation = sessionTranslate && translationLanguage != nil
            let needsPolish = !sessionTranslate && polishEnabled
            let needsLLM = (needsTranslation || needsPolish) && llmService.isAvailable

            if needsLLM {
                await MainActor.run {
                    stage = .translating
                    if needsPolish {
                        statusText = "Polishing..."
                        overlayVM.isPolish = true
                    } else {
                        statusText = "Translating..."
                    }
                    setOverlayStage(.translating, asr: text)
                }

                guard !Task.isCancelled, stage != .idle else { return }

                let llmStart = Date()
                let result: String
                if needsTranslation, let lang = translationLanguage {
                    result = try await llmService.translate(text, to: lang, polish: polishEnabled)
                } else {
                    result = try await llmService.polish(text)
                }
                let llmElapsed = Date().timeIntervalSince(llmStart)
                log("[LLM] \(String(format: "%.1f", llmElapsed))s -- \(result.prefix(80))")

                guard !Task.isCancelled, stage != .idle else { return }

                await MainActor.run {
                    gptText = result
                    gptAccum = result
                    setOverlayStage(.translating, asr: text, gpt: result)
                }
            } else if needsTranslation && !llmService.isAvailable {
                log("[VibeVoice] Translation requested but no LLM API key set, using raw transcription")
            } else if needsPolish && !llmService.isAvailable {
                log("[VibeVoice] Polish enabled but no LLM API key set, using raw transcription")
            }

            guard !Task.isCancelled, stage != .idle else { return }

            await MainActor.run {
                finishSession()
            }
        } catch {
            guard !Task.isCancelled, stage != .idle else { return }
            await MainActor.run {
                log("[VibeVoice] Error: \(error)")
                stage = .error
                statusText = "Error: \(error.localizedDescription)"
                setOverlayStage(.error)
                scheduleReset(delay: 3.0)
            }
        }
    }

    // MARK: - Finish

    /// Strip trailing period for short single-sentence results.
    private func trimTrailingPunctuation(_ text: String) -> String {
        var s = text
        let midPunct: [Character] = [".", "\u{3002}", "!", "\u{FF01}", "?", "\u{FF1F}"]
        let body = s.dropLast()
        let hasMidPunct = body.contains(where: { midPunct.contains($0) })
        if !hasMidPunct, let last = s.last, last == "." || last == "\u{3002}" {
            s.removeLast()
        }
        return s
    }

    private func finishSession() {
        guard stage != .idle else { return }
        stage = .done

        // If GPT returned a refusal, discard it and use raw ASR text
        if !gptText.isEmpty && LLMService.looksLikeRefusal(gptText) {
            log("[AppState] GPT refusal detected, falling back to ASR text")
            gptText = ""
        }

        let raw = gptText.isEmpty ? asrText : gptText
        let finalText = trimTrailingPunctuation(raw)
        statusText = "Done"
        setOverlayStage(.done, asr: asrText, gpt: gptText)
        log("[AppState] Finish -- text=\"\(finalText.prefix(80))\"")

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
        // isPolish is set separately where needed (not reset here to avoid clearing it mid-session)
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
        overlayVM.stage = .idle
        overlayVM.asrText = ""
        overlayVM.gptText = ""
        overlayVM.isPolish = false
    }

    // MARK: - Persistence

    private static let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".SuperVibe")
    private static let configFile = configDir.appendingPathComponent("config.json")

    static func loadConfigValue(_ key: String) -> Any? {
        guard let data = try? Data(contentsOf: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json[key]
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: Self.configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let lang = json["translation_language"] as? String {
            translationLanguage = lang
        }
        if let raw = json["engine"] as? String, let mode = EngineMode(rawValue: raw) {
            engineMode = mode
        }
        if let modelId = json["vibevoice_model"] as? String,
           let model = VibeVoiceSTT.availableModels.first(where: { $0.id == modelId }) {
            vibeVoice.selectModel(model)
        }
        if let key = json["llm_api_key"] as? String, !key.isEmpty {
            llmService.apiKey = key
        }
        if let polish = json["polish_enabled"] as? Bool {
            polishEnabled = polish
        }
        if let modelId = json["llm_model"] as? String,
           let model = LLMService.availableModels.first(where: { $0.id == modelId }) {
            llmService.selectedModel = model
        }
    }

    func saveConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.configDir, withIntermediateDirectories: true)

        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.configFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }

        if let lang = translationLanguage {
            config["translation_language"] = lang
        } else {
            config.removeValue(forKey: "translation_language")
        }

        config["engine"] = engineMode.rawValue
        config["vibevoice_model"] = vibeVoice.currentModel.id

        if let key = llmService.apiKey, !key.isEmpty {
            config["llm_api_key"] = key
        } else {
            config.removeValue(forKey: "llm_api_key")
        }

        config["polish_enabled"] = polishEnabled
        config["llm_model"] = llmService.selectedModel.id

        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.configFile)
        }
    }
}
