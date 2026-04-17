import Foundation

final class PipelineClient: @unchecked Sendable {

    // MARK: - Callbacks

    var onASRDelta: (@Sendable (String) -> Void)?
    var onASRDone: (@Sendable (String, TimeInterval) -> Void)?
    var onGPTDelta: (@Sendable (String) -> Void)?
    var onGPTDone: (@Sendable (String, TimeInterval) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onDone: (@Sendable (TimeInterval) -> Void)?

    // MARK: - State

    private let baseURL: URL
    private let timeout: TimeInterval
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private var pingTask: Task<Void, Never>?

    private let sendLock = NSLock()
    private var sendQueue: [Data] = []
    private var sessionStarted = false

    var isConnected: Bool { webSocketTask != nil }

    // MARK: - Init

    enum ClientError: LocalizedError {
        case invalidURL(String)
        var errorDescription: String? {
            switch self {
            case .invalidURL(let s): return "Invalid pipeline URL: \(s)"
            }
        }
    }

    init(url: String, timeout: TimeInterval) throws {
        guard let parsed = URL(string: url) else {
            throw ClientError.invalidURL(url)
        }
        self.baseURL = parsed
        self.timeout = timeout
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Connection

    func connect(clientVersion: String, deviceId: String) async throws {
        let task = session.webSocketTask(with: baseURL)
        task.resume()
        webSocketTask = task
        startPing()
        log("[Pipeline] WebSocket connecting to: \(baseURL)")

        // Send hello handshake (Vibing protocol)
        let hello: [String: Any] = [
            "type": "hello",
            "client_version": clientVersion,
            "device_id": deviceId,
        ]
        try await sendJSON(hello)
        log("[Pipeline] Hello sent")
    }

    // MARK: - Send Helper

    private func sendJSON(_ dict: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard let json = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        log("[Pipeline] >>> \(json.prefix(300))")
        try await webSocketTask?.send(.string(json))
    }

    // MARK: - Session

    func startSession(config: [String: Any]) async throws {
        try await sendJSON(config)
        log("[Pipeline] Session config sent")

        // Replay buffered audio chunks
        let buffered: [Data] = {
            sendLock.lock()
            defer { sendLock.unlock() }
            sessionStarted = true
            let q = sendQueue
            sendQueue.removeAll()
            return q
        }()

        if !buffered.isEmpty {
            log("[Pipeline] Replaying \(buffered.count) buffered chunks")
        }
        for chunk in buffered {
            webSocketTask?.send(.data(chunk)) { _ in }
        }
    }

    // MARK: - Audio Streaming

    func sendAudioChunk(_ data: Data) {
        sendLock.lock()
        if sessionStarted {
            sendLock.unlock()
            webSocketTask?.send(.data(data)) { error in
                if let error {
                    log("[Pipeline] Audio chunk send error: \(error)")
                }
            }
        } else {
            sendQueue.append(data)
            sendLock.unlock()
        }
    }

    // MARK: - Stop

    func stopSession() {
        let msg: [String: Any] = ["type": "stop", "client_stop_sent": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        log("[Pipeline] Sending stop: \(str)")
        webSocketTask?.send(.string(str)) { error in
            if let error {
                log("[Pipeline] Stop send error: \(error)")
            } else {
                log("[Pipeline] Stop sent OK")
            }
        }
    }

    // MARK: - Receive Loop

    func receiveUntilDone() async {
        guard let task = webSocketTask else {
            log("[Pipeline] receiveUntilDone: no webSocketTask!")
            return
        }
        log("[Pipeline] Receive loop started (timeout=\(timeout)s per frame)")

        let frameTimeout = timeout
        while true {
            do {
                // Race the receive against a timeout so a dead server doesn't leak the task forever.
                let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                    group.addTask { try await task.receive() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(frameTimeout * 1_000_000_000))
                        throw URLError(.timedOut)
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                switch message {
                case .string(let text):
                    log("[Pipeline] <<< \(text.prefix(200))")
                    if handleMessage(text) { return }
                case .data(let data):
                    log("[Pipeline] <<< (binary \(data.count) bytes)")
                    if let text = String(data: data, encoding: .utf8) {
                        if handleMessage(text) { return }
                    }
                @unknown default:
                    break
                }
            } catch {
                log("[Pipeline] Receive error: \(error)")
                onError?("WebSocket error: \(error.localizedDescription)")
                webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
                return
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            log("[Pipeline] Unrecognized message (no 'type')")
            return false
        }

        switch type {
        case "asr_delta":
            if let t = json["text"] as? String { onASRDelta?(t) }

        case "asr_done":
            let t = json["text"] as? String
                ?? json["asr_raw_response_text"] as? String ?? ""
            let elapsed = json["elapsed"] as? Double ?? 0
            onASRDone?(t, elapsed)

        case "gpt_delta":
            if let t = json["text"] as? String { onGPTDelta?(t) }

        case "gpt_done":
            let t = json["gpt_text"] as? String
                ?? json["text"] as? String ?? ""
            let elapsed = json["elapsed"] as? Double ?? 0
            onGPTDone?(t, elapsed)

        case "error":
            let msg = json["error"] as? String
                ?? json["message"] as? String ?? "Unknown error"
            onError?(msg)

        case "done":
            let elapsed = json["elapsed"] as? Double ?? 0
            onDone?(elapsed)
            log("[Pipeline] Done (\(String(format: "%.2f", elapsed))s)")
            return true

        default:
            log("[Pipeline] Unknown message type: \(type)")
        }
        return false
    }

    // MARK: - Ping

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.webSocketTask?.sendPing { error in
                    if let error {
                        log("[Pipeline] Ping failed: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Cleanup

    func close() {
        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        sendLock.lock()
        sessionStarted = false
        sendQueue.removeAll()
        sendLock.unlock()
    }

    deinit { close() }
}
