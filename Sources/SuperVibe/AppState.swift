import Cocoa
import SwiftUI

/// Core state machine: one dictation at a time.
///
///     idle ──start──▶ recording ──stop──▶ recognizing ──▶ translating ──▶ done ──▶ idle
///                         │                    │   (polish / translate,      ▲
///                         │                    └───── skipped if not needed) ┘
///                         └──────── any failure ──▶ error ──(3 s)──▶ idle
///
/// ESC (`cancelSession`) returns to idle from every state.
///
/// Every dictation gets a new `generation`. Deferred work (timers, LLM
/// requests, context capture) records the generation it belongs to and
/// does nothing if a newer one has started, so a stale callback can never
/// act on a later dictation.
@MainActor
final class AppState {

    // MARK: - State

    private(set) var stage: PipelineStage = .idle
    private(set) var isRecording = false
    private var asrText = ""
    private var gptText = ""
    private var sessionTranslate = false
    private var generation = 0
    private var asrSession: Int?
    /// The final text of the last dictation has been pasted; only the
    /// overlay's closing delay remains.
    private var pasteDelivered = false

    // MARK: - Settings

    var polishEnabled = true {
        didSet { saveConfig() }
    }
    var translationLanguage: String? {
        didSet { saveConfig() }
    }
    /// Snapshot what is on screen when recording starts and use it to
    /// bias both the ASR (hotwords) and the LLM (disambiguation).
    var ambientContextEnabled = true {
        didSet { saveConfig() }
    }

    var llmApiKey: String? {
        get { llmService.apiKey }
        set {
            llmService.apiKey = newValue
            saveConfig()
        }
    }

    var geminiApiKey: String? {
        get { llmService.geminiApiKey }
        set {
            llmService.geminiApiKey = newValue
            saveConfig()
        }
    }

    var llmProvider: LLMProvider {
        get { llmService.provider }
        set {
            llmService.provider = newValue
            saveConfig()
            onConfigChanged?()
        }
    }

    // MARK: - Services

    let vibeVoice = VibeVoiceSTT()
    let llmService = LLMService()
    private(set) var vibeVoiceAvailable = false

    // Auto-correction: track the user's small edits to pasted text and
    // feed them back as hotwords and as few-shot examples for the LLM.
    private let correctionStore = CorrectionStore()
    private let editTracker = EditTracker()

    /// Context of the current dictation, captured when recording starts
    /// so it describes the app the text will be pasted into.
    private var sessionContext = LLMService.Context()

    /// Called when isRecording changes (for menu bar icon update).
    var onRecordingChanged: ((Bool) -> Void)?
    /// Called when engine/config changes (for menu rebuild).
    var onConfigChanged: (() -> Void)?
    /// Called when a user action fails and needs a visible alert.
    var onAlert: ((String, String) -> Void)?

    // MARK: - Private

    private let audioRecorder = AudioRecorder(sampleRate: VibeVoiceSTT.inputSampleRate)
    private let hotkeyManager = HotkeyManager()
    private var overlayPanel: OverlayPanel?
    private let overlayVM = OverlayViewModel()
    private var llmTask: Task<Void, Never>?
    private let contextQueue = DispatchQueue(label: "com.supervibe.context", qos: .userInitiated)

    private var isLoadingConfig = false
    /// Debounce save-to-disk; callers mutate properties freely and we coalesce writes.
    private var pendingSave: DispatchWorkItem?
    /// Cached config dict — avoids re-reading the file on every save.
    private var cachedConfig: [String: Any] = [:]

    // MARK: - Init

    init() {
        loadConfig()
        editTracker.onCorrection = { [correctionStore] correction in
            correctionStore.append(correction)
        }
        vibeVoice.onDelta = { [weak self] session, text in
            self?.handleASRDelta(session: session, text: text)
        }
        vibeVoice.onDone = { [weak self] session, text in
            self?.handleASRDone(session: session, text: text)
        }
        vibeVoice.onError = { [weak self] session, message in
            self?.handleASRError(session: session, message: message)
        }
        vibeVoice.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.overlayVM.isModelLoading = (state == .loading)
            self.onConfigChanged?()
        }
    }

    func toggleAmbientContext() {
        ambientContextEnabled.toggle()
        log("[AppState] Ambient context: \(ambientContextEnabled ? "ON" : "OFF")")
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

    // MARK: - ASR model

    func selectVibeModel(_ model: VibeVoiceSTT.Model) {
        if stage != .idle { cancelSession() }
        vibeVoice.selectModel(model)
        vibeVoice.warmup()
        saveConfig()
        log("[AppState] ASR model: \(model.name)")
        onConfigChanged?()
    }

    /// Check for the mlx-audio installation and, if present, load the model.
    func checkVibeVoiceAvailability() {
        let vibeVoice = self.vibeVoice
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let available = vibeVoice.isAvailable()
            DispatchQueue.main.async {
                guard let self else { return }
                self.vibeVoiceAvailable = available
                if available { vibeVoice.warmup() }
                self.onConfigChanged?()
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
        } else if translationLanguage == nil {
            onAlert?("Translation Not Configured", "Please select a target language in the Translation menu before using the translate shortcut.")
        } else if !llmService.isAvailable {
            onAlert?("LLM API Key Required", "Translation is done by the LLM. Set an API key in the menu before using the translate shortcut.")
        } else {
            startRecording(translate: true)
        }
    }

    // MARK: - Start

    func startRecording(translate: Bool) {
        // The closing delay of the previous dictation (result or error
        // still on screen) must not block the next one.
        if stage == .error || (stage == .done && pasteDelivered) {
            hideOverlay()
            stage = .idle
        }
        guard stage == .idle else {
            log("[AppState] startRecording skipped, stage=\(stage)")
            return
        }

        generation += 1
        let gen = generation
        sessionTranslate = translate
        pasteDelivered = false

        // Capture the target app NOW (before our overlay/menu steals focus)
        // so context and corrections are keyed to the app the user intends
        // to paste into.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleId = frontApp?.bundleIdentifier
        let appName = frontApp?.localizedName ?? ""
        let pid = frontApp?.processIdentifier ?? 0

        asrText = ""; gptText = ""
        sessionContext = LLMService.Context()
        stage = .recording
        isRecording = true
        onRecordingChanged?(true)
        log("[AppState] Recording started -- mode=\(translate ? "translate(\(translationLanguage ?? "?"))" : "transcribe"), model=\(vibeVoice.currentModel.id)")

        overlayVM.asrText = ""
        overlayVM.gptText = ""
        overlayVM.errorText = ""
        overlayVM.isPolish = false
        overlayVM.isTranslation = translate
        overlayVM.stage = .recording
        showOverlay()

        // Microphone first: the session buffers audio until its context is
        // committed below, so nothing the user says is lost while the
        // context is being collected.
        let vibeVoice = self.vibeVoice
        let session = vibeVoice.openSession()
        asrSession = session
        audioRecorder.onAudioLevel = { [weak self] level in
            self?.overlayVM.pushLevel(level)
        }
        audioRecorder.onAudioChunk = { chunk in
            vibeVoice.sendAudio(session, chunk)
        }
        do {
            try audioRecorder.start()
        } catch {
            fail("Mic error: \(error.localizedDescription)")
            return
        }

        // Context (screen text, corrections, hotwords) is collected off the
        // main thread: the AX walk is synchronous IPC into another process.
        let wantAmbient = ambientContextEnabled
            && bundleId.map { !AppProfiles.isSensitive(bundleId: $0) } == true
        if ambientContextEnabled, let bundleId, !wantAmbient {
            log("[Ambient] skipped (sensitive app: \(bundleId))")
        }
        let correctionStore = self.correctionStore
        contextQueue.async { [weak self] in
            var ambient: AmbientSnapshot?
            if wantAmbient, let bundleId {
                ambient = FocusedContext.captureAmbient(pid: pid, bundleId: bundleId, appName: appName)
                if let snap = ambient {
                    log("[Ambient] AX captured \(snap.visibleWindowText.count) chars from \(snap.appName) (window: \(snap.windowTitle.prefix(60)))")
                }
            }
            let corrections = bundleId.map { correctionStore.recent(matching: $0, limit: 30) } ?? []
            let hotwords = HotwordBuilder.build(ambient: ambient, corrections: corrections)
            if !hotwords.isEmpty {
                log("[ASR] hotwords: \(hotwords.count) terms [\(hotwords.prefix(8).joined(separator: ", "))\(hotwords.count > 8 ? ", ..." : "")]")
            }

            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.sessionContext = LLMService.Context(
                    profile: bundleId.flatMap { AppProfiles.hint(for: $0) },
                    ambient: ambient,
                    corrections: Array(corrections.prefix(6))
                )
                vibeVoice.commitSession(session, context: hotwords.joined(separator: ", "))
            }
        }
    }

    // MARK: - Cancel (ESC)

    func cancelSession() {
        guard stage != .idle else { return }
        log("[AppState] Session cancelled")
        abortCurrentWork()
        hideOverlay()
        stage = .idle
    }

    /// Stop everything belonging to the current dictation and invalidate
    /// its pending callbacks.
    private func abortCurrentWork() {
        generation += 1
        editTracker.stopTrack()
        llmTask?.cancel()
        llmTask = nil
        if let session = asrSession {
            vibeVoice.cancelSession(session)
            asrSession = nil
        }
        stopMicrophone()
    }

    private func stopMicrophone() {
        audioRecorder.onAudioChunk = nil
        audioRecorder.stop()
        overlayVM.resetLevels()
        if isRecording {
            isRecording = false
            onRecordingChanged?(false)
        }
    }

    // MARK: - Stop

    func stopRecording() {
        guard isRecording, stage == .recording, let session = asrSession else { return }
        stopMicrophone()
        stage = .recognizing
        setOverlayStage(.recognizing, asr: asrText)
        vibeVoice.finishSession(session)
        log("[AppState] Recording stopped, finishing transcription")
    }

    // MARK: - ASR events

    private func handleASRDelta(session: Int, text: String) {
        guard session == asrSession, stage == .recording || stage == .recognizing else { return }
        asrText += text
        overlayVM.asrText = asrText
    }

    private func handleASRDone(session: Int, text: String) {
        guard session == asrSession, stage == .recognizing else { return }
        asrSession = nil
        asrText = text

        guard !text.isEmpty else {
            log("[AppState] No speech detected")
            scheduleReset(delay: 1.0)
            return
        }
        setOverlayStage(.recognizing, asr: text)

        let needsTranslation = sessionTranslate && translationLanguage != nil
        let needsPolish = !sessionTranslate && polishEnabled
        guard (needsTranslation || needsPolish), llmService.isAvailable else {
            if needsTranslation || needsPolish {
                log("[AppState] No LLM API key set, using raw transcription")
            }
            finishSession()
            return
        }

        stage = .translating
        overlayVM.isPolish = needsPolish
        setOverlayStage(.translating, asr: text)

        let gen = generation
        let context = sessionContext
        let language = translationLanguage
        let polish = polishEnabled
        let llm = llmService
        llmTask = Task { [weak self] in
            let started = Date()
            do {
                let result: String
                if needsTranslation, let language {
                    result = try await llm.translate(text, to: language, polish: polish, context: context)
                } else {
                    result = try await llm.polish(text, context: context)
                }
                guard let self, self.generation == gen else { return }
                log("[LLM] \(String(format: "%.1f", Date().timeIntervalSince(started)))s -- \(result.prefix(80))")
                self.gptText = result
                self.setOverlayStage(.translating, asr: text, gpt: result)
                self.finishSession()
            } catch {
                guard let self, self.generation == gen else { return }
                // The transcription itself succeeded; losing it because the
                // post-processing request failed would discard the user's
                // speech. Paste the raw text instead.
                log("[LLM] Error, using raw transcription: \(error.localizedDescription)")
                self.finishSession()
            }
        }
    }

    private func handleASRError(session: Int?, message: String) {
        // A failure without a session (server could not start, model failed
        // to load) only concerns a dictation that is waiting on the server.
        if let session {
            guard session == asrSession else { return }
        } else {
            guard asrSession != nil else { return }
        }
        guard stage == .recording || stage == .recognizing else { return }
        fail(message)
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
        guard stage == .recognizing || stage == .translating else { return }
        stage = .done

        let raw = gptText.isEmpty ? asrText : gptText
        let finalText = trimTrailingPunctuation(raw)
        setOverlayStage(.done, asr: asrText, gpt: gptText)
        log("[AppState] Finish -- text=\"\(finalText.prefix(80))\"")

        guard !finalText.isEmpty else {
            scheduleReset(delay: 1.0)
            return
        }

        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.generation == gen else { return }
            PasteService.paste(finalText)
            self.pasteDelivered = true
            self.editTracker.startTrack(insertedText: finalText)
        }
        scheduleReset(delay: 1.5)
    }

    /// Enter the error state, show the reason, and return to idle after 3 s.
    private func fail(_ message: String) {
        log("[AppState] Error: \(message)")
        abortCurrentWork()
        stage = .error
        overlayVM.errorText = message
        setOverlayStage(.error)
        showOverlay()
        scheduleReset(delay: 3.0)
    }

    /// Return to idle after `delay`, unless another dictation (or a cancel)
    /// has taken over in the meantime.
    private func scheduleReset(delay: Double) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.hideOverlay()
            self.stage = .idle
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
        overlayVM.resetLevels()
        overlayPanel?.contentView = nil   // tear down SwiftUI view tree (kills all animations & timers)
        overlayPanel?.orderOut(nil)
        overlayPanel = nil                // next showOverlay() will recreate
        overlayVM.stage = .idle
        overlayVM.asrText = ""
        overlayVM.gptText = ""
        overlayVM.errorText = ""
        overlayVM.isPolish = false
    }

    // MARK: - Persistence

    private static let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".SuperVibe")
    private static let configFile = configDir.appendingPathComponent("config.json")

    private func loadConfig() {
        guard let data = try? Data(contentsOf: Self.configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        cachedConfig = json

        // Property observers call saveConfig(); while loading, that would
        // snapshot a half-populated state and write it back over the file.
        isLoadingConfig = true
        defer { isLoadingConfig = false }

        if let lang = json["translation_language"] as? String {
            translationLanguage = lang
        }
        if let modelId = json["asr_model"] as? String,
           let model = VibeVoiceSTT.availableModels.first(where: { $0.id == modelId }) {
            vibeVoice.selectModel(model, restart: false)
        }
        if let key = json["llm_api_key"] as? String, !key.isEmpty {
            llmService.apiKey = key
        }
        if let key = json["gemini_api_key"] as? String, !key.isEmpty {
            llmService.geminiApiKey = key
        }
        if let raw = json["llm_provider"] as? String, let p = LLMProvider(rawValue: raw) {
            llmService.provider = p
        }
        if let polish = json["polish_enabled"] as? Bool {
            polishEnabled = polish
        }
        if let ambient = json["ambient_context_enabled"] as? Bool {
            ambientContextEnabled = ambient
        }
        if let modelId = json["llm_model"] as? String,
           let model = LLMService.claudeModels.first(where: { $0.id == modelId }) {
            llmService.selectedModel = model
        }
        if let modelId = json["gemini_model"] as? String,
           let model = LLMService.geminiModels.first(where: { $0.id == modelId }) {
            llmService.selectedGeminiModel = model
        }
    }

    /// Debounced save. Repeated calls within 500ms coalesce into a single disk write.
    func saveConfig() {
        guard !isLoadingConfig else { return }

        if let lang = translationLanguage {
            cachedConfig["translation_language"] = lang
        } else {
            cachedConfig.removeValue(forKey: "translation_language")
        }
        cachedConfig["asr_model"] = vibeVoice.currentModel.id
        // Keys of the removed cloud engine.
        cachedConfig.removeValue(forKey: "engine")
        cachedConfig.removeValue(forKey: "vibevoice_model")

        if let key = llmService.apiKey, !key.isEmpty {
            cachedConfig["llm_api_key"] = key
        } else {
            cachedConfig.removeValue(forKey: "llm_api_key")
        }
        if let key = llmService.geminiApiKey, !key.isEmpty {
            cachedConfig["gemini_api_key"] = key
        } else {
            cachedConfig.removeValue(forKey: "gemini_api_key")
        }

        cachedConfig["llm_provider"] = llmService.provider.rawValue
        cachedConfig["polish_enabled"] = polishEnabled
        cachedConfig["ambient_context_enabled"] = ambientContextEnabled
        cachedConfig["llm_model"] = llmService.selectedModel.id
        cachedConfig["gemini_model"] = llmService.selectedGeminiModel.id

        // Debounce disk write.
        pendingSave?.cancel()
        let snapshot = cachedConfig
        let directory = Self.configDir
        let file = Self.configFile
        let work = DispatchWorkItem {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: file, options: .atomic)
                // The file holds API keys: owner read/write only.
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
