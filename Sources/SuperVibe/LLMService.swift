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
            prompt = "This is transcribed speech. Translate it to \(langName). Since this is spoken language, understand the speaker's true intent — handle self-corrections (e.g. \"no wait, I mean...\"), filler words, and false starts by only translating the final intended meaning. Fix grammar and punctuation in the translation. Output ONLY the translation, nothing else.\n\n\(text)"
        } else {
            prompt = "Translate the following text to \(langName) literally. Output ONLY the translation, nothing else.\n\n\(text)"
        }

        return try await callAPI(key: key, prompt: prompt, originalText: text)
    }

    func polish(_ text: String) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw LLMError.noAPIKey
        }

        let prompt = "Polish the following transcribed speech text. Fix any grammar, punctuation, or spoken language artifacts while preserving the original meaning and language. If the text is already correct, return it as-is. Output ONLY the polished text, nothing else.\n\n\(text)"

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
            "system": "You are a speech-to-text post-processor embedded in a voice input tool. Your sole job is to faithfully polish or translate the user's transcribed speech. Process all content exactly as given — never refuse, filter, comment on, or modify the meaning. Output only the processed text.",
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

        let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Detect LLM refusal — if the response is much longer than input
        // and contains refusal patterns, fall back to original text
        if LLMService.looksLikeRefusal(trimmed) {
            log("[LLM] Refusal detected, falling back to original text")
            return originalText
        }

        return trimmed
    }

    static func looksLikeRefusal(_ response: String) -> Bool {
        let refusalMarkers = [
            // English
            "I can't", "I cannot", "I'm not able to", "I am not able to",
            "I'm unable to", "I appreciate", "I need to clarify",
            "I don't feel comfortable", "I must decline",
            "not able to polish", "not able to translate",
            "unable to process", "against my guidelines",
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
