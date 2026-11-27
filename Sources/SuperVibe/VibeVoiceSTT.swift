import Foundation

/// Client for the persistent Python ASR server (`Resources/vibevoice_server.py`).
///
/// The server keeps one model loaded and speaks a JSON-lines protocol over
/// stdin/stdout. A session is a single dictation:
///
///     openSession ──▶ (audio buffered locally) ──▶ commitSession(context)
///                                                        │ start + buffered audio
///     sendAudio ─────────────────────────────────────────┤
///     finishSession ──▶ stop ──▶ … delta … ──▶ done      │
///     cancelSession ──▶ cancel                           ▼
///
/// `openSession` returns immediately so the microphone can start before the
/// hotword context is known; audio is buffered until `commitSession`.
///
/// Threading: session bookkeeping and every pipe write run on `writeQueue`,
/// so no caller (in particular the audio tap thread) ever blocks on the
/// pipe. `lock` guards the small amount of state read from other threads.
/// Callbacks are always delivered on the main queue.
final class VibeVoiceSTT: @unchecked Sendable {

    struct Model {
        let name: String
        let id: String
        /// Streaming checkpoints emit text while audio is still arriving.
        let streaming: Bool
    }

    static let availableModels: [Model] = [
        .init(name: "Streaming 7B 4bit (~5.7GB)", id: "mlx-community/VibeVoice-ASR-Streaming-7B-4bit", streaming: true),
        .init(name: "Streaming 1.5B (~5.6GB)", id: "microsoft/VibeVoice-ASR-Streaming-1.5B", streaming: true),
        .init(name: "Streaming 7B bf16 (~17GB)", id: "mlx-community/VibeVoice-ASR-Streaming-7B-bf16", streaming: true),
        .init(name: "Long-form 4bit, no streaming (~5GB)", id: "mlx-community/VibeVoice-ASR-4bit", streaming: false),
        .init(name: "Long-form bf16, no streaming (~18GB)", id: "mlx-community/VibeVoice-ASR-bf16", streaming: false),
    ]

    /// Sample rate of the PCM passed to `sendAudio` (Int16 mono).
    static let inputSampleRate = 24000

    enum ServerState: Equatable {
        case stopped
        case loading
        case ready
        case failed(String)
    }

    // MARK: - Callbacks (main queue)

    var onDelta: ((_ session: Int, _ text: String) -> Void)?
    var onDone: ((_ session: Int, _ text: String) -> Void)?
    /// `session` is nil when the failure is not tied to one dictation
    /// (server could not start, model failed to load).
    var onError: ((_ session: Int?, _ message: String) -> Void)?
    var onStateChanged: ((ServerState) -> Void)?

    // MARK: - State

    private let lock = NSLock()
    private var _state: ServerState = .stopped
    private var _model: Model = availableModels[0]
    private var _nextSessionId = 0
    /// Mirror of `process` readable from any thread (for `shutdown`).
    private var _runningProcess: Process?

    var state: ServerState { lock.withLock { _state } }
    var currentModel: Model { lock.withLock { _model } }

    // Everything below is confined to `writeQueue`.
    private let writeQueue = DispatchQueue(label: "com.supervibe.asr.write", qos: .userInitiated)
    private var process: Process?
    private var stdinHandle: FileHandle?

    private struct Session {
        let id: Int
        var committed = false
        var finishRequested = false
        var buffered: [Data] = []
    }
    private var session: Session?

    // MARK: - Availability

    /// True when a Python interpreter with `mlx_audio` importable exists.
    /// Spawns a process; call off the main thread.
    func isAvailable() -> Bool {
        guard let python = Self.findPython() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import mlx_audio"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Server lifecycle

    /// Select the model. Restarts the server if it was running a different one.
    func selectModel(_ model: Model, restart: Bool = true) {
        let changed = lock.withLock { () -> Bool in
            guard _model.id != model.id else { return false }
            _model = model
            return true
        }
        guard changed, restart else { return }
        writeQueue.async {
            let wasRunning = self.process != nil
            self.terminateProcess()
            if wasRunning { self.ensureRunning() }
        }
    }

    /// Start the server and load the model, if not already running.
    func warmup() {
        writeQueue.async { self.ensureRunning() }
    }

    /// Terminate the server now. Does not wait for `writeQueue`, which could
    /// be blocked on a pipe write if the server stopped reading.
    func shutdown() {
        let p = lock.withLock { _runningProcess }
        p?.terminationHandler = nil
        p?.terminate()
        writeQueue.async { self.terminateProcess() }
    }

    deinit {
        let p = lock.withLock { _runningProcess }
        p?.terminationHandler = nil
        p?.terminate()
    }

    // MARK: - Sessions

    /// Allocate a session. Audio sent before `commitSession` is buffered.
    func openSession() -> Int {
        let id = lock.withLock { () -> Int in
            _nextSessionId += 1
            return _nextSessionId
        }
        writeQueue.async {
            if let old = self.session, old.committed {
                self.send(["op": "cancel", "id": old.id])
            }
            self.session = Session(id: id)
            self.ensureRunning()
        }
        return id
    }

    /// Send the session's hotword context; flushes audio buffered so far.
    func commitSession(_ id: Int, context: String) {
        writeQueue.async {
            guard var s = self.session, s.id == id, !s.committed else { return }
            self.send([
                "op": "start",
                "id": id,
                "rate": Self.inputSampleRate,
                "context": context,
            ])
            for chunk in s.buffered { self.sendAudioFrame(id, chunk) }
            s.buffered.removeAll()
            s.committed = true
            if s.finishRequested { self.send(["op": "stop", "id": id]) }
            self.session = s
        }
    }

    /// Int16 mono PCM at `inputSampleRate`. Safe to call from any thread.
    func sendAudio(_ id: Int, _ pcm: Data) {
        writeQueue.async {
            guard self.session?.id == id else { return }
            if self.session?.committed == true {
                self.sendAudioFrame(id, pcm)
            } else {
                self.session?.buffered.append(pcm)
            }
        }
    }

    /// No more audio: transcribe what is still buffered, then emit `onDone`.
    func finishSession(_ id: Int) {
        writeQueue.async {
            guard self.session?.id == id else { return }
            if self.session?.committed == true {
                self.send(["op": "stop", "id": id])
            } else {
                self.session?.finishRequested = true
            }
        }
    }

    func cancelSession(_ id: Int) {
        writeQueue.async {
            guard let s = self.session, s.id == id else { return }
            if s.committed { self.send(["op": "cancel", "id": id]) }
            self.session = nil
        }
    }

    // MARK: - Process management (writeQueue)

    private func ensureRunning() {
        if let process, process.isRunning { return }
        process = nil
        stdinHandle = nil

        guard let python = Self.findPython() else {
            fail(session: session?.id, "mlx-audio not found. Install it with: pipx install mlx-audio")
            session = nil
            return
        }
        guard let script = Self.findScript() else {
            fail(session: session?.id, "vibevoice_server.py not found in the app resources")
            session = nil
            return
        }

        let model = currentModel
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script, model.id]
        var env = ProcessInfo.processInfo.environment
        env["TOKENIZERS_PARALLELISM"] = "false"
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.standardError

        proc.terminationHandler = { [weak self] p in
            self?.writeQueue.async { self?.processExited(p) }
        }

        do {
            try proc.run()
        } catch {
            fail(session: session?.id, "Failed to launch ASR server: \(error.localizedDescription)")
            session = nil
            return
        }

        process = proc
        lock.withLock { _runningProcess = proc }
        stdinHandle = stdinPipe.fileHandleForWriting
        setState(.loading)
        log("[ASR] Server starting, model=\(model.id)")

        let reader = Thread { [weak self] in
            Self.readLines(from: stdoutPipe.fileHandleForReading) { line in
                self?.handleEvent(line, from: proc)
            }
        }
        reader.name = "com.supervibe.asr.read"
        reader.start()
    }

    private func processExited(_ p: Process) {
        guard process === p else { return }  // an old server we already replaced
        process = nil
        lock.withLock { _runningProcess = nil }
        stdinHandle = nil
        let status = p.terminationStatus
        log("[ASR] Server exited (status \(status))")
        // A load failure already reported its own, more specific, message.
        let alreadyFailed: Bool = { if case .failed = state { return true } else { return false } }()
        if !alreadyFailed {
            setState(.stopped)
            if let s = session {
                fail(session: s.id, "ASR server exited unexpectedly (status \(status))", setState: false)
            }
        }
        session = nil
    }

    private func terminateProcess() {
        guard let p = process else { return }
        p.terminationHandler = nil
        try? stdinHandle?.close()   // EOF on stdin makes the server exit by itself
        p.terminate()
        process = nil
        lock.withLock { _runningProcess = nil }
        stdinHandle = nil
        session = nil
        setState(.stopped)
    }

    // MARK: - Protocol (writeQueue for sends, reader thread for events)

    private func sendAudioFrame(_ id: Int, _ pcm: Data) {
        send(["op": "audio", "id": id, "pcm": pcm.base64EncodedString()])
    }

    private func send(_ message: [String: Any]) {
        guard let handle = stdinHandle,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            // The server died; its termination handler reports the failure.
            log("[ASR] Write failed: \(error.localizedDescription)")
        }
    }

    private func handleEvent(_ line: String, from proc: Process) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String
        else {
            log("[ASR] Unrecognized server output: \(line.prefix(200))")
            return
        }
        let id = json["id"] as? Int

        switch event {
        case "ready":
            let mem = json["active_memory_gb"] as? Double ?? 0
            let load = json["load_sec"] as? Double ?? 0
            let streaming = json["streaming"] as? Bool ?? false
            log("[ASR] Server ready in \(String(format: "%.1f", load))s (streaming=\(streaming), model memory \(String(format: "%.1f", mem)) GB)")
            writeQueue.async {
                guard self.process === proc else { return }
                self.setState(.ready)
            }

        case "delta":
            guard let id, let text = json["text"] as? String else { return }
            DispatchQueue.main.async { self.onDelta?(id, text) }

        case "done":
            guard let id else { return }
            let text = json["text"] as? String ?? ""
            let audio = json["audio_sec"] as? Double ?? 0
            let compute = json["compute_sec"] as? Double ?? 0
            log("[ASR] done: audio \(String(format: "%.1f", audio))s, compute \(String(format: "%.1f", compute))s -- \(text.prefix(80))")
            writeQueue.async {
                if self.session?.id == id { self.session = nil }
            }
            DispatchQueue.main.async { self.onDone?(id, text) }

        case "error":
            let message = json["error"] as? String ?? "unknown error"
            writeQueue.async {
                guard self.process === proc else { return }
                if let id {
                    if self.session?.id == id { self.session = nil }
                    self.fail(session: id, message, setState: false)
                } else {
                    // Not tied to a session: the model failed to load.
                    let active = self.session?.id
                    self.session = nil
                    self.fail(session: active, message)
                }
            }

        default:
            log("[ASR] Unknown event: \(event)")
        }
    }

    private func setState(_ new: ServerState) {
        let changed = lock.withLock { () -> Bool in
            guard _state != new else { return false }
            _state = new
            return true
        }
        guard changed else { return }
        DispatchQueue.main.async { self.onStateChanged?(new) }
    }

    private func fail(session id: Int?, _ message: String, setState updateState: Bool = true) {
        log("[ASR] Error: \(message)")
        if updateState { setState(.failed(message)) }
        DispatchQueue.main.async { self.onError?(id, message) }
    }

    /// Blocking line reader. Returns when the pipe reaches EOF.
    private static func readLines(from handle: FileHandle, _ onLine: (String) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    onLine(line)
                }
            }
        }
    }

    // MARK: - Discovery

    private static func findPython() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots: [String] = []
        if let pipxHome = ProcessInfo.processInfo.environment["PIPX_HOME"], !pipxHome.isEmpty {
            roots.append(pipxHome)
        }
        roots += [
            "\(home)/.local/pipx",
            "\(home)/.local/share/pipx",
            "\(home)/Library/Application Support/pipx",
        ]
        for root in roots {
            let python = "\(root)/venvs/mlx-audio/bin/python3"
            if FileManager.default.isExecutableFile(atPath: python) { return python }
        }
        return nil
    }

    private static func findScript() -> String? {
        if let url = Bundle.module.url(forResource: "vibevoice_server", withExtension: "py", subdirectory: "Resources") {
            return url.path
        }
        let devPath = FileManager.default.currentDirectoryPath + "/Sources/SuperVibe/Resources/vibevoice_server.py"
        return FileManager.default.fileExists(atPath: devPath) ? devPath : nil
    }
}
