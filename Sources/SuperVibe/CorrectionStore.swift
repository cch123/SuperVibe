import Foundation

/// One recorded user correction — what we pasted vs. what the user ended
/// up with after a short editing window. Stored locally, scoped per-app.
struct Correction: Codable {
    let timestamp: Date
    let bundleId: String
    let appName: String
    let insertedText: String         // what PasteService pasted
    let userEditedText: String       // the user's final version of that span
    let triggerReason: String        // focus_switch | timeout | enter | clear
}

/// Append-only JSONL store at ~/.SuperVibe/corrections.jsonl. Capped to
/// `maxLines` entries by rewriting the file on append when the cap is hit.
/// Thread-safe: writes are serialized on `queue`; the file is replaced
/// atomically, so a concurrent read sees either the old or the new content.
final class CorrectionStore: @unchecked Sendable {

    private static let dir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".SuperVibe")
    private static let file = dir.appendingPathComponent("corrections.jsonl")

    private let maxLines: Int
    private let queue = DispatchQueue(label: "com.supervibe.corrections", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(maxLines: Int = 500) {
        self.maxLines = maxLines
    }

    func append(_ correction: Correction) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(
                    at: Self.dir, withIntermediateDirectories: true
                )
                var lines = readAllLines()
                if let data = try? encoder.encode(correction),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                    if lines.count > maxLines {
                        lines = Array(lines.suffix(maxLines))
                    }
                    let content = lines.joined(separator: "\n") + "\n"
                    try content.write(to: Self.file, atomically: true, encoding: .utf8)
                    log("[Correction] saved (\(correction.bundleId)): \"\(correction.insertedText.prefix(40))\" -> \"\(correction.userEditedText.prefix(40))\"")
                }
            } catch {
                log("[Correction] save failed: \(error)")
            }
        }
    }

    /// Most-recent corrections for the given bundle, newest first.
    /// Runs synchronously on the caller's thread — read from the JSONL on disk.
    func recent(matching bundleId: String, limit: Int = 6) -> [Correction] {
        let lines = readAllLines()
        var out: [Correction] = []
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let c = try? decoder.decode(Correction.self, from: data)
            else { continue }
            if c.bundleId == bundleId {
                out.append(c)
                if out.count >= limit { break }
            }
        }
        return out
    }

    private func readAllLines() -> [String] {
        guard let data = try? Data(contentsOf: Self.file),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
