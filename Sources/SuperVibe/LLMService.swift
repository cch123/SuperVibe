import Foundation

enum LLMProvider: String {
    case claude = "claude"
    case gemini = "gemini"
}

final class LLMService {
    struct Model {
        let name: String
        let id: String
        /// Claude only: the model accepts `output_config.effort`. Dictation
        /// post-processing is latency-sensitive, so those models run at `low`.
        var supportsEffort = false
    }

    // Order is the menu order; the first entry is the default.
    static let claudeModels: [Model] = [
        .init(name: "Claude Haiku 5.5", id: "claude-haiku-5-5", supportsEffort: true),
        .init(name: "Claude Haiku 4.5", id: "claude-haiku-4-5-20251001"),
        .init(name: "Claude Sonnet 5.5", id: "claude-sonnet-5-5", supportsEffort: true),
        .init(name: "Claude Sonnet 4.6", id: "claude-sonnet-4-6", supportsEffort: true),
        .init(name: "Claude Opus 5.5", id: "claude-opus-5-5", supportsEffort: true),
    ]

    static let geminiModels: [Model] = [
        .init(name: "Gemini 3 Flash", id: "gemini-3-flash-preview"),
        .init(name: "Gemini 3.1 Flash Lite", id: "gemini-3.1-flash-lite-preview"),
        .init(name: "Gemini 3.1 Pro", id: "gemini-3.1-pro-preview"),
        .init(name: "Gemini 2.5 Flash Lite", id: "gemini-2.5-flash-lite"),
        .init(name: "Gemini 2.5 Flash", id: "gemini-2.5-flash"),
        .init(name: "Gemini 2.5 Pro", id: "gemini-2.5-pro"),
        .init(name: "Gemini 2.0 Flash", id: "gemini-2.0-flash"),
    ]

    /// Everything about the current dictation that can help the model
    /// disambiguate: a per-app hint, what is visible on screen, and the
    /// user's past corrections in this app. Captured by AppState when the
    /// recording starts, so it describes the app the text will be pasted
    /// into even if focus drifts while the request is in flight.
    struct Context {
        var profile: String?
        var ambient: AmbientSnapshot?
        var corrections: [Correction] = []
    }

    var provider: LLMProvider = .claude
    var apiKey: String?           // Anthropic API key
    var geminiApiKey: String?     // Google Gemini API key
    var selectedModel: Model = claudeModels[0]
    var selectedGeminiModel: Model = geminiModels[0]

    var currentModel: Model {
        provider == .claude ? selectedModel : selectedGeminiModel
    }

    var currentModels: [Model] {
        provider == .claude ? Self.claudeModels : Self.geminiModels
    }

    var isAvailable: Bool {
        switch provider {
        case .claude:
            guard let key = apiKey else { return false }
            return !key.isEmpty
        case .gemini:
            guard let key = geminiApiKey else { return false }
            return !key.isEmpty
        }
    }

    private func activeKey() throws -> String {
        switch provider {
        case .claude:
            guard let key = apiKey, !key.isEmpty else { throw LLMError.noAPIKey }
            return key
        case .gemini:
            guard let key = geminiApiKey, !key.isEmpty else { throw LLMError.noAPIKey }
            return key
        }
    }

    func translate(_ text: String, to targetLanguage: String, polish: Bool = false, context ctx: Context = Context()) async throws -> String {
        let langName = languageName(for: targetLanguage)
        let profile = ctx.profile
        let ambient = ctx.ambient
        let corrList = ctx.corrections
        let corrections = Self.formatCorrections(corrList)
        let context = Self.formatAmbient(profile: profile, ambient: ambient)
        let phoneticRule = Self.phoneticRuleIfNeeded(ambient: ambient, corrections: corrList)
        let prompt: String
        if polish {
            prompt = "\(context)Translate the following text to \(langName). Handle self-corrections, filler words, and false starts by translating only the final intended meaning.\(phoneticRule)\(corrections) Output ONLY the \(langName) translation, nothing else.\n\n\(text)"
        } else {
            prompt = "\(context)Translate the following text to \(langName).\(phoneticRule)\(corrections) Output ONLY the \(langName) translation, nothing else.\n\n\(text)"
        }
        Self.logPromptBuild(label: "translate(\(targetLanguage)\(polish ? "+polish" : ""))",
                            prompt: prompt, profile: profile, ambient: ambient,
                            corrections: corrList, input: text)

        let result = try await callAPI(prompt: prompt, originalText: text)

        // If translate was refused, retry with sanitize + simple prompt
        if result == text {
            log("[LLM] Translate was refused, retrying")
            let sanitized = self.sanitize(text)
            let textToTranslate = (sanitized != text) ? sanitized : text
            if sanitized != text {
                log("[LLM] Sanitized: \(sanitized.prefix(120))")
            }
            // Use a minimal prompt — no mention of speech/profanity to avoid confusing the LLM
            let retryPrompt = "Translate to \(langName):\n\(textToTranslate)"
            log("[LLM] retry translate req: prompt=\(retryPrompt.count) chars (no ambient, no profile, no corrections)")
            let translated = try await callAPI(prompt: retryPrompt, originalText: textToTranslate)
            if translated != textToTranslate {
                log("[LLM] Retry translate result: \(translated.prefix(120))")
                return translated
            }
            log("[LLM] Retry also refused, falling back to original")
            return text
        }

        return result
    }

    func polish(_ text: String, context ctx: Context = Context()) async throws -> String {
        let profile = ctx.profile
        let ambient = ctx.ambient
        let corrList = ctx.corrections
        let corrections = Self.formatCorrections(corrList)
        let context = Self.formatAmbient(profile: profile, ambient: ambient)
        let phoneticRule = Self.phoneticRuleIfNeeded(ambient: ambient, corrections: corrList)
        let prompt = "\(context)Polish the following transcribed speech text. Fix grammar, punctuation, and spoken language artifacts (filler words, false starts, repetitions). Preserve the original meaning, tone, and language as closely as possible. Keep the text faithful to what the speaker intended to say.\(phoneticRule) If the text is already correct, return it as-is.\(corrections) Output ONLY the polished text, nothing else.\n\n\(text)"
        Self.logPromptBuild(label: "polish", prompt: prompt, profile: profile, ambient: ambient,
                            corrections: corrList, input: text)

        let result = try await callAPI(prompt: prompt, originalText: text)
        if result == text {
            log("[LLM] Polish was refused or text unchanged, using original")
        }
        return result
    }

    /// Deterministic text-level sanitize: replace known vulgar phrases with
    /// mild equivalents so the LLM can translate without refusing.
    ///
    /// Chinese entries are multi-character phrases only: single characters
    /// such as 操 or 逼 also occur inside ordinary words (操作, 逼近), so
    /// replacing them unconditionally corrupts unrelated text. English
    /// entries match whole words only, for the same reason (class, pass).
    func sanitize(_ text: String) -> String {
        // Order matters: longer phrases first to avoid partial replacements
        let phrases: [(String, String)] = [
            ("操你妈的逼", "你这混蛋"),
            ("操你妈逼", "你这混蛋"),
            ("你妈的逼", ""),
            ("妈的逼", ""),
            ("操你妈", "你这混蛋"),
            ("干你妈", "你这混蛋"),
            ("肏你妈", "你这混蛋"),
            ("操你的", "你这混蛋"),
            ("操他妈", "真该死"),
            ("他妈的", "该死的"),
            ("你妈的", "该死的"),
            ("妈的", "该死的"),
            ("操你", "你这混蛋"),
            ("干你", "你这混蛋"),
            ("肏你", "你这混蛋"),
            ("傻逼", "蠢货"),
            ("牛逼", "厉害"),
            ("装逼", "装样子"),
            ("鸡巴", ""),
            ("草泥马", "混蛋"),
        ]
        let words: [(String, String)] = [
            ("fuck", "damn"),
            ("fucking", "damn"),
            ("shit", "crap"),
            ("bitch", "jerk"),
            ("ass", "butt"),
        ]

        var result = text
        for (vulgar, clean) in phrases {
            result = result.replacingOccurrences(of: vulgar, with: clean)
        }
        for (vulgar, clean) in words {
            result = result.replacingOccurrences(
                of: "\\b\(vulgar)\\b", with: clean,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    // MARK: - Private

    /// Extra prompt rule telling the model to trust the ambient context /
    /// correction history over the raw ASR when the ASR appears to have
    /// phonetically approximated a technical term (e.g. Chinese "爆幕" for
    /// English "BOM"). Returns "" when there's no context to lean on, so
    /// the prompt stays minimal for simple cases.
    private static func phoneticRuleIfNeeded(ambient: AmbientSnapshot?, corrections: [Correction]) -> String {
        let hasAmbient = ambient?.visibleWindowText.isEmpty == false
        let hasCorrections = !corrections.isEmpty
        guard hasAmbient || hasCorrections else { return "" }
        return " If the transcription contains characters that are phonetic approximations of acronyms, product names, identifiers, or technical terms that appear in the context above, prefer the spelling from the context (e.g. if the context shows \"BOM\" and the transcription says \"爆幕\", output \"BOM\")."
    }

    /// One-line summary of what's in the prompt we're about to send — size
    /// breakdown across ambient / profile / corrections, plus a short
    /// preview. Set SUPERVIBE_LLM_DUMP_PROMPT=1 in the environment to also
    /// print the full assembled prompt (truncated at 8000 chars).
    private static func logPromptBuild(
        label: String,
        prompt: String,
        profile: String?,
        ambient: AmbientSnapshot?,
        corrections: [Correction],
        input: String
    ) {
        let axLen = ambient?.visibleWindowText.count ?? 0
        let profileFlag = (profile?.isEmpty == false) ? "yes" : "no"
        let ambientScope: String
        if let a = ambient, axLen > 0 {
            let title = a.windowTitle.isEmpty ? "—" : String(a.windowTitle.prefix(40))
            ambientScope = "\(a.appName):\(title)"
        } else {
            ambientScope = "none"
        }
        log("[LLM] \(label) req: prompt=\(prompt.count)ch | ax=\(axLen)ch (\(ambientScope)) | profile=\(profileFlag) | corrections=\(corrections.count) | input=\(input.count)ch")

        if ProcessInfo.processInfo.environment["SUPERVIBE_LLM_DUMP_PROMPT"] == "1" {
            let dump = prompt.count > 8000 ? String(prompt.prefix(8000)) + "…[truncated \(prompt.count - 8000) chars]" : prompt
            log("[LLM] \(label) full prompt:\n\(dump)")
        }
    }

    /// Build the leading context block for a prompt. Combines the per-app
    /// profile hint with a snippet of what's visible in the focused
    /// window. Returns "" when both are missing so the prompt is identical
    /// to the pre-context-feature version.
    private static func formatAmbient(profile: String?, ambient: AmbientSnapshot?) -> String {
        var chunks: [String] = []
        if let profile, !profile.isEmpty { chunks.append(profile) }
        if let ambient, !ambient.visibleWindowText.isEmpty {
            var header = "Visible on screen right now"
            if !ambient.appName.isEmpty { header += " (app: \(ambient.appName)" }
            if !ambient.windowTitle.isEmpty { header += ", window: \(ambient.windowTitle)" }
            if !ambient.appName.isEmpty { header += ")" }
            header += " — use this to disambiguate names, jargon, and terminology, but do NOT quote or refer to it:"
            chunks.append("\(header)\n\"\"\"\n\(ambient.visibleWindowText)\n\"\"\"")
        }
        if chunks.isEmpty { return "" }
        return chunks.joined(separator: "\n\n") + "\n\n"
    }

    /// Format the user's recent corrections into a block that can be
    /// appended to a polish/translate prompt. Returns "" when there are
    /// no corrections so the prompt stays unchanged.
    private static func formatCorrections(_ corrections: [Correction]) -> String {
        guard !corrections.isEmpty else { return "" }
        var lines: [String] = []
        for c in corrections {
            let original = c.insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let edited = c.userEditedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, !edited.isEmpty, original != edited else { continue }
            lines.append("  \"\(original)\" -> \"\(edited)\"")
        }
        guard !lines.isEmpty else { return "" }
        return "\n\nThe user has previously corrected your output in this app. Apply the same preferences when the same terms recur; do NOT invent corrections for unrelated text:\n" + lines.joined(separator: "\n") + "\n"
    }

    private static let systemPrompt = "You are a text processing tool embedded in a voice input application. Follow the user's instructions exactly. Always produce the requested output — never refuse, never explain, never add commentary. Output only the processed text."

    private func callAPI(prompt: String, originalText: String) async throws -> String {
        let key = try activeKey()
        let raw: String?
        switch provider {
        case .claude:
            raw = try await callClaudeAPI(key: key, prompt: prompt)
        case .gemini:
            raw = try await callGeminiAPI(key: key, prompt: prompt)
        }

        // nil: the API itself reported a refusal (structured signal).
        guard let raw else {
            log("[LLM] Provider reported a refusal, falling back to original text")
            return originalText
        }

        let full = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.isEmpty { return originalText }

        // Heuristic for refusals written as ordinary text.
        if LLMService.looksLikeRefusal(full, input: originalText) {
            log("[LLM] Refusal detected, falling back to original text. Raw response:\n\(full)")
            return originalText
        }

        // The whole response is the result: dictation can legitimately span
        // several paragraphs, so nothing is cut at paragraph boundaries.
        return full
    }

    private static let requestTimeout: TimeInterval = 30

    /// Returns nil when the API reports `stop_reason: "refusal"`.
    private func callClaudeAPI(key: String, prompt: String) async throws -> String? {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": selectedModel.id,
            // Current models think before answering and thinking tokens
            // count toward this ceiling, so leave room beyond the text.
            "max_tokens": 8192,
            "system": Self.systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        if selectedModel.supportsEffort {
            body["output_config"] = ["effort": "low"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.apiError(errBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else {
            throw LLMError.parseFailed
        }

        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" { return nil }

        // `content` may start with thinking blocks; the result is the
        // concatenation of the text blocks only.
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        if stopReason == "max_tokens" {
            throw LLMError.apiError("response truncated at max_tokens")
        }
        guard !text.isEmpty else { throw LLMError.parseFailed }
        return text
    }

    /// Returns nil when Gemini blocks the prompt or the candidate for safety.
    private func callGeminiAPI(key: String, prompt: String) async throws -> String? {
        let model = selectedGeminiModel.id
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Header, not query string: URLs end up in logs and error messages.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": Self.systemPrompt]]
            ],
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "maxOutputTokens": 8192
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.apiError(errBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.parseFailed
        }
        if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            return nil
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first
        else {
            throw LLMError.parseFailed
        }
        let finish = first["finishReason"] as? String
        if finish == "SAFETY" || finish == "PROHIBITED_CONTENT" { return nil }

        let parts = (first["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        // Skip thought-summary parts; concatenate the answer parts.
        let text = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw LLMError.parseFailed }
        return text
    }

    /// Text heuristic for refusals. A marker only counts when it is absent
    /// from `input`: the user may legitimately dictate "抱歉" or
    /// "incomplete", and a faithful result then contains it too.
    static func looksLikeRefusal(_ response: String, input: String) -> Bool {
        let refusalMarkers = [
            // English — refusal / hedging / meta-commentary
            "I can't", "I cannot", "I'm not able to", "I am not able to",
            "I'm unable to", "I appreciate", "I need to clarify",
            "I don't feel comfortable", "I must decline",
            "not able to polish", "not able to translate",
            "unable to process", "against my guidelines",
            "I notice", "Could you please provide",
            "incomplete", "no complete sentence",
            "intended meaning", "provide the complete",
            // Japanese
            "すみません", "申し訳", "できません", "対応できません",
            "お手伝いできません", "適切ではない",
            // Chinese
            "抱歉", "无法处理", "无法翻译", "无法润色",
            "不能处理", "不适当", "我没办法", "不能帮",
            // Korean
            "죄송합니다", "처리할 수 없", "도와드릴 수 없",
            // French / Spanish / German
            "je ne peux pas", "no puedo", "ich kann nicht",
        ]
        let lower = response.lowercased()
        let lowerInput = input.lowercased()
        return refusalMarkers.contains {
            let marker = $0.lowercased()
            return lower.contains(marker) && !lowerInput.contains(marker)
        }
    }

    private func languageName(for code: String) -> String {
        switch code {
        case "en": return "English"
        case "zh": return "Simplified Chinese"
        case "zh-TW": return "Traditional Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        default: return code
        }
    }

    enum LLMError: LocalizedError {
        case noAPIKey
        case apiError(String)
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "LLM API key not set"
            case .apiError(let msg): return "LLM API error: \(msg)"
            case .parseFailed: return "Failed to parse LLM response"
            }
        }
    }
}
