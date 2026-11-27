import Foundation

/// Builds the hotword list passed to the ASR model as recognition context,
/// so it is biased toward terms the user actually uses.
///
/// Ranked by signal strength:
///   0. User-curated list at `~/.SuperVibe/hotwords.txt` (a permanent
///      dictionary — their equivalent of Typeless's user dictionary).
///   1. Tokens from the user's recent corrections (authoritative — this is
///      what they *wanted* to see instead of what ASR gave them).
///   2. ALL-CAPS acronyms (BOM, API, SKU, URL, JSON).
///   3. CamelCase / PascalCase identifiers (useState, PostgreSQL, iPhone).
///   4. snake_case / kebab-case identifiers (text_insertion_point,
///      web-components).
///   5. Multi-letter standalone English words inside a Chinese-heavy AX dump
///      (often technical brand / product names).
///
/// Output is deduplicated. Automatically derived terms (1–5) only fill the
/// list up to `maxHotwords` entries in total. That cap is deliberately
/// small: the list becomes part of the ASR prompt, and irrelevant terms
/// actively hurt. Measured on VibeVoice-ASR-Streaming-7B-4bit with one
/// test clip: 4 relevant terms plus up to 8 irrelevant ones transcribed
/// correctly, 24 irrelevant ones made it substitute listed terms for
/// similar-sounding words that were actually spoken.
enum HotwordBuilder {

    /// Where the user's manual dictionary lives.
    static let userHotwordsFile: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".SuperVibe")
        .appendingPathComponent("hotwords.txt")

    static func build(
        ambient: AmbientSnapshot?,
        corrections: [Correction],
        maxHotwords: Int = 16,
        maxUserHotwords: Int = 32
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func add(_ token: String) {
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, t.count <= 40 else { return }
            guard !seen.contains(t) else { return }
            seen.insert(t)
            ordered.append(t)
        }

        // 0. User-curated list. Highest priority so the user can guarantee
        // specific terms always ride along with every ASR request.
        // The user's list has its own, larger cap: it is explicit intent,
        // whereas the terms below are guesses.
        for t in userHotwords() {
            add(t)
            if ordered.count >= maxUserHotwords { break }
        }

        // 1. Recent corrections (user-validated, scoped to this app).
        for c in corrections {
            for t in extractTokens(from: c.userEditedText) {
                add(t)
                if ordered.count >= maxHotwords { break }
            }
            if ordered.count >= maxHotwords { break }
        }

        // 2–5. AX ambient text.
        if ordered.count < maxHotwords, let ax = ambient?.visibleWindowText, !ax.isEmpty {
            for t in extractTokens(from: ax) {
                add(t)
                if ordered.count >= maxHotwords { break }
            }
        }

        return ordered
    }

    /// Parse `~/.SuperVibe/hotwords.txt`. Lines starting with `#` or `//`
    /// are comments; blank lines are skipped. Missing file → empty list.
    static func userHotwords() -> [String] {
        guard let text = try? String(contentsOf: userHotwordsFile, encoding: .utf8) else {
            return []
        }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
    }

    /// Ensure the hotwords file exists on disk, seeded with an explanation
    /// and a couple of starter entries. Called when the user asks to edit
    /// the file so a newcomer sees usage instructions, not a blank file.
    @discardableResult
    static func ensureUserHotwordsFileExists() -> URL {
        let dir = userHotwordsFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: userHotwordsFile.path) {
            let seed = """
            # SuperVibe hotwords — one term per line.
            #
            # These are sent to the ASR on every recording so it knows to
            # prefer them over phonetic approximations. Use this for:
            #   - Project / product names (SuperVibe, Typeless)
            #   - Your own name, teammate names, company names
            #   - Acronyms you say in English inside another language (BOM, API)
            #   - Technical terms ASR keeps mangling
            #
            # Lines starting with # or // are ignored. Blank lines are ignored.

            SuperVibe
            Typeless
            """
            try? seed.write(to: userHotwordsFile, atomically: true, encoding: .utf8)
        }
        return userHotwordsFile
    }

    // MARK: - Token extraction

    private static func extractTokens(from text: String) -> [String] {
        var hits: [String] = []

        // ALL-CAPS acronyms (2–10 chars). Matters most for ASR because these
        // are the terms Chinese users say in English and ASR transliterates.
        for match in text.matches(of: #/\b[A-Z][A-Z0-9]{1,9}\b/#) {
            hits.append(String(match.output))
        }

        // CamelCase / PascalCase (two+ capitalized groups).
        for match in text.matches(of: #/\b[A-Z][a-z]+(?:[A-Z][a-z0-9]+){1,}\b/#) {
            hits.append(String(match.output))
        }

        // snake_case / kebab-case identifiers.
        for match in text.matches(of: #/\b[a-zA-Z][a-zA-Z0-9]*[_\-][a-zA-Z0-9][a-zA-Z0-9_\-]*\b/#) {
            hits.append(String(match.output))
        }

        // Standalone English words of length 4+ embedded in CJK-heavy text
        // (often brand / product names). In predominantly English text this
        // rule would match every ordinary word, so it is skipped there.
        // The trailing delimiter is a lookahead: consuming it would make the
        // next word unmatchable when the two are separated by one character.
        if isCJKHeavy(text) {
            for match in text.matches(of: #/(?:^|[^A-Za-z])([A-Za-z]{4,20})(?![A-Za-z])/#) {
                hits.append(String(match.output.1))
            }
        }

        return hits
    }

    /// True when at least a fifth of the letters are CJK ideographs or kana.
    private static func isCJKHeavy(_ text: String) -> Bool {
        var cjk = 0, letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF:
                cjk += 1
            default:
                break
            }
        }
        return letters > 0 && cjk * 5 >= letters
    }
}
