import Foundation

final class LLMService {
    struct Model {
        let name: String
        let id: String
    }

    static let availableModels: [Model] = [
        .init(name: "Claude Haiku 4.5", id: "claude-haiku-4-5-20251001"),
        .init(name: "Claude Sonnet 4", id: "claude-sonnet-4-20250514"),
        .init(name: "Claude Sonnet 4.6", id: "claude-sonnet-4-6-20250725"),
    ]

    var apiKey: String?
    var selectedModel: Model = availableModels[0]

    var isAvailable: Bool {
        guard let key = apiKey else { return false }
        return !key.isEmpty
    }

    func translate(_ text: String, to targetLanguage: String, polish: Bool = false) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw LLMError.noAPIKey
        }

        let langName = languageName(for: targetLanguage)
        let prompt: String
        if polish {
            prompt = "Translate the following text to \(langName). Handle self-corrections, filler words, and false starts by translating only the final intended meaning. Output ONLY the \(langName) translation, nothing else.\n\n\(text)"
        } else {
            prompt = "Translate the following text to \(langName). Output ONLY the \(langName) translation, nothing else.\n\n\(text)"
        }

        let result = try await callAPI(key: key, prompt: prompt, originalText: text)

        // If translate was refused, retry with sanitize + simple prompt
        if result == text {
            log("[LLM] Translate was refused, retrying")
            let sanitized = try await self.sanitize(text)
            let textToTranslate = (sanitized != text) ? sanitized : text
            if sanitized != text {
                log("[LLM] Sanitized: \(sanitized.prefix(120))")
            }
            // Use a minimal prompt — no mention of speech/profanity to avoid confusing the LLM
            let retryPrompt = "Translate to \(langName):\n\(textToTranslate)"
            let translated = try await callAPI(key: key, prompt: retryPrompt, originalText: textToTranslate)
            if translated != textToTranslate {
                log("[LLM] Retry translate result: \(translated.prefix(120))")
                return translated
            }
            log("[LLM] Retry also refused, falling back to original")
        }

        return text
    }

    func polish(_ text: String) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw LLMError.noAPIKey
        }

        let prompt = "Polish the following transcribed speech text. Fix grammar, punctuation, and spoken language artifacts (filler words, false starts, repetitions). Preserve the original meaning, tone, and language as closely as possible. Keep the text faithful to what the speaker intended to say. If the text is already correct, return it as-is. Output ONLY the polished text, nothing else.\n\n\(text)"

        return try await callAPI(key: key, prompt: prompt, originalText: text)
    }

    /// Sanitize: rewrite vulgar/offensive content into polite equivalents.
    /// Used as fallback when translate is refused.
    func sanitize(_ text: String) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw LLMError.noAPIKey
        }

        let prompt = "Minimally edit the following text in the same language. Remove sexually explicit content but keep the same aggressive attitude and emotion. Replace sexual expressions with non-sexual insults or curses that preserve the tone. Output ONLY the edited text as a single line, nothing else.\n\n\(text)"

        return try await callAPI(key: key, prompt: prompt, originalText: text)
    }

    // MARK: - Private

    private func callAPI(key: String, prompt: String, originalText: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": selectedModel.id,
            "max_tokens": 1024,
            "system": "You are a text processing tool embedded in a voice input application. Follow the user's instructions exactly. Always produce the requested output — never refuse, never explain, never add commentary. Output only the processed text.",
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.apiError(errBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let resultText = firstContent["text"] as? String
        else {
            throw LLMError.parseFailed
        }

        // Take only the first paragraph — strip alternatives/commentary
        let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n").first?
            .components(separatedBy: "\n(").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? resultText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Detect LLM refusal — check if the response is meta-commentary
        // rather than actual processed text
        if LLMService.looksLikeRefusal(trimmed) {
            log("[LLM] Refusal detected (raw: \(trimmed.prefix(120))), falling back to original text")
            return originalText
        }

        return trimmed
    }

    static func looksLikeRefusal(_ response: String) -> Bool {
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
        return refusalMarkers.contains { lower.contains($0.lowercased()) }
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
