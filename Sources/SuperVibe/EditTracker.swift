import Foundation

/// Watches the focused input box for ~15s after a paste, detects small
/// user edits to the pasted text, and reports them as corrections.
/// Mirrors Typeless's `hf` class (`dist/main/index.js:9047`): same stop
/// conditions, same large-modify heuristics, polling-only (no key tap).
final class EditTracker {

    /// Called when a small, stable edit is detected and should be recorded.
    var onCorrection: ((Correction) -> Void)?

    // MARK: - Tuning constants (aligned with Typeless)

    private let postPasteCaptureDelay: TimeInterval = 0.3      // wait for Cmd+V to land
    private let pollInterval: TimeInterval = 0.5
    private let maxTrackTime: TimeInterval = 15.0

    /// Upper-bound the stored field snapshots to avoid keeping huge blobs.
    private let maxStoredFieldChars = 2000

    // MARK: - State

    private var insertedText: String = ""
    private var originalSnapshot: FocusedSnapshot?
    private var pollTimer: Timer?
    private var stopTimer: Timer?
    private var isTracking = false

    // MARK: - Public API

    /// Called from AppState right after PasteService.paste(finalText) is
    /// scheduled. Internally waits `postPasteCaptureDelay` before taking
    /// the "original" snapshot so the paste has time to land.
    func startTrack(insertedText: String) {
        stopTrack()
        guard !insertedText.isEmpty else { return }
        self.insertedText = insertedText

        DispatchQueue.main.asyncAfter(deadline: .now() + postPasteCaptureDelay) { [weak self] in
            self?.captureOriginalAndBegin()
        }
    }

    func stopTrack() {
        pollTimer?.invalidate(); pollTimer = nil
        stopTimer?.invalidate(); stopTimer = nil
        isTracking = false
        originalSnapshot = nil
        insertedText = ""
    }

    // MARK: - Lifecycle

    private func captureOriginalAndBegin() {
        guard let snap = FocusedContext.capture() else {
            log("[EditTracker] no focused element, aborting")
            return
        }
        guard snap.isEditable else {
            log("[EditTracker] focus not editable (role=\(snap.role)), aborting")
            return
        }
        let normalized = Self.normalize(snap.fullFieldContent)
        let normalizedInsert = Self.normalize(insertedText)
        guard normalized.contains(normalizedInsert) else {
            log("[EditTracker] inserted text not found in focused field, aborting")
            return
        }

        originalSnapshot = snap
        isTracking = true
        log("[EditTracker] tracking started in \(snap.bundleId) (role=\(snap.role))")

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        stopTimer = Timer.scheduledTimer(withTimeInterval: maxTrackTime, repeats: false) { [weak self] _ in
            self?.finalize(reason: "timeout")
        }
    }

    private func poll() {
        guard isTracking, let original = originalSnapshot else {
            stopTrack(); return
        }
        guard let now = FocusedContext.capture() else {
            finalize(reason: "no_focus")
            return
        }
        if now.identityKey != original.identityKey {
            finalize(reason: "focus_switch")
            return
        }
        if now.fullFieldContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // content cleared — discard, don't save
            log("[EditTracker] content cleared, discarding")
            stopTrack()
            return
        }
        // If the inserted text is still fully present verbatim, user hasn't
        // edited it yet — keep polling.
        let nowNorm = Self.normalize(now.fullFieldContent)
        let insertNorm = Self.normalize(insertedText)
        if nowNorm.contains(insertNorm) {
            return
        }
        // User edited: check if it's a small, plausible correction.
        let origNorm = Self.normalize(original.fullFieldContent)
        let analysis = Self.analyze(original: origNorm, current: nowNorm, inserted: insertNorm)
        if analysis.isLargeModify {
            log("[EditTracker] large modify (added=\(analysis.added) removed=\(analysis.removed)), discarding")
            stopTrack()
        }
        // Otherwise: small edit in progress, keep polling until stop/timeout.
        // (We finalize on focus_switch or timeout — never mid-edit.)
    }

    private func finalize(reason: String) {
        guard isTracking, let original = originalSnapshot else {
            stopTrack(); return
        }
        defer { stopTrack() }

        guard let finalSnap = FocusedContext.capture() else { return }

        let origNorm = Self.normalize(original.fullFieldContent)
        let nowNorm = Self.normalize(finalSnap.fullFieldContent)
        let insertNorm = Self.normalize(insertedText)

        if nowNorm.contains(insertNorm) {
            // No change — don't record.
            return
        }
        if nowNorm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        let analysis = Self.analyze(original: origNorm, current: nowNorm, inserted: insertNorm)
        if analysis.isLargeModify {
            return
        }

        // Extract the edited version of the inserted span, using the
        // before/after anchors captured at paste time.
        let edited = Self.extractEditedSpan(
            originalBefore: original.textBeforeCursor,
            originalAfter: original.textAfterCursor,
            originalInserted: insertedText,
            currentFull: finalSnap.fullFieldContent
        )
        guard let userEdit = edited, !userEdit.isEmpty, userEdit != insertedText else {
            return
        }

        let correction = Correction(
            timestamp: Date(),
            bundleId: original.bundleId,
            appName: original.appName,
            insertedText: String(insertedText.prefix(maxStoredFieldChars)),
            userEditedText: String(userEdit.prefix(maxStoredFieldChars)),
            triggerReason: reason
        )
        onCorrection?(correction)
    }

    // MARK: - Pure helpers

    static func normalize(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\r", with: "")
        out = out.replacingOccurrences(of: "\n", with: "")
        let zeroWidth: [Character] = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{FEFF}"]
        out.removeAll(where: { zeroWidth.contains($0) })
        return out
    }

    struct Analysis {
        let isLargeModify: Bool
        let added: Int
        let removed: Int
        let changed: Int
    }

    /// Ported from Typeless `analysisModification` (index.js:9302). Same
    /// thresholds: 20%/50%/200% of the original length.
    static func analyze(original: String, current: String, inserted: String) -> Analysis {
        let origChars = Array(original.prefix(1000))
        let curChars = Array(current.prefix(1000))

        let diff = curChars.difference(from: origChars)
        let added = diff.insertions.count
        let removed = diff.removals.count
        let changed = added + removed

        let origLen = origChars.count
        let curLen = current.count

        // Shrank to <20% of original → treat as large/destructive change.
        if curLen < Int(Double(original.count) * 0.2) {
            return .init(isLargeModify: true, added: added, removed: removed, changed: changed)
        }
        // Deleted >50% of original → large.
        if removed > Int(Double(origLen) * 0.5) {
            return .init(isLargeModify: true, added: added, removed: removed, changed: changed)
        }
        // Total churn >200% of original → large.
        if changed > origLen * 2 {
            return .init(isLargeModify: true, added: added, removed: removed, changed: changed)
        }
        return .init(isLargeModify: false, added: added, removed: removed, changed: changed)
    }

    /// Given the cursor context at paste time (text before / after the
    /// pasted span) and the current full-field content, locate the edited
    /// version of the inserted span.
    ///
    /// We anchor on the longest stable prefix of `before` and the longest
    /// stable suffix of `after` that we can still find in `currentFull`.
    /// Everything between those anchors is the user's edited span.
    static func extractEditedSpan(
        originalBefore: String,
        originalAfter: String,
        originalInserted: String,
        currentFull: String
    ) -> String? {
        // Anchor lengths — small enough to stay stable across minor nearby
        // edits, big enough to avoid false matches in long fields.
        let anchorLen = 24
        let before = String(originalBefore.suffix(anchorLen))
        let after = String(originalAfter.prefix(anchorLen))

        // Try trimming the anchor progressively if not found.
        func findAnchor(_ anchor: String, in haystack: String, fromEnd: Bool) -> String.Index? {
            var a = anchor
            while !a.isEmpty {
                if fromEnd {
                    if let r = haystack.range(of: a, options: .backwards) { return r.lowerBound }
                } else {
                    if let r = haystack.range(of: a) { return r.upperBound }
                }
                a = String(a.dropFirst())
            }
            return nil
        }

        let startIdx: String.Index
        if before.isEmpty {
            startIdx = currentFull.startIndex
        } else if let idx = findAnchor(before, in: currentFull, fromEnd: false) {
            startIdx = idx
        } else {
            return nil
        }

        let endIdx: String.Index
        if after.isEmpty {
            endIdx = currentFull.endIndex
        } else if let idx = findAnchor(after, in: currentFull, fromEnd: true), idx >= startIdx {
            endIdx = idx
        } else {
            endIdx = currentFull.endIndex
        }

        let span = String(currentFull[startIdx..<endIdx])
        // Sanity: span shouldn't be absurdly larger than the original.
        if span.count > originalInserted.count * 4 + 50 {
            return nil
        }
        return span
    }
}
