import Cocoa
import ApplicationServices

/// Snapshot of the currently focused app + text input field, captured via
/// macOS Accessibility APIs. Mirrors the role of Typeless's `getFullContext`.
struct FocusedSnapshot {
    let appName: String
    let bundleId: String
    let pid: pid_t
    let role: String
    let identifier: String          // kAXIdentifierAttribute (often empty)
    let windowTitle: String

    let fullFieldContent: String
    let textBeforeCursor: String
    let textAfterCursor: String
    let selectedText: String
    let isEditable: Bool

    /// Stable-ish key to detect "user switched focus away from this input".
    /// If any of these components change between two polls, we treat it as
    /// focus switch and stop tracking.
    var identityKey: String {
        "\(bundleId)|\(pid)|\(role)|\(identifier)|\(windowTitle)"
    }
}

/// Ambient context: a short snippet of whatever's visible in the focused
/// window right now. Used to bias LLM polish/translate toward the
/// vocabulary of the scene the user is actually looking at.
struct AmbientSnapshot {
    let bundleId: String
    let appName: String
    let windowTitle: String
    /// Concatenated visible text from the focused window's AX tree, deduped
    /// and capped at `maxVisibleChars`.
    let visibleWindowText: String
}

enum FocusedContext {

    /// UTF-16 units of field content kept on each side of the cursor.
    private static let fieldWindow = 4000

    /// Capture the currently focused app + text element. Returns nil if
    /// Accessibility permission is missing or no focused element exists.
    static func capture() -> FocusedSnapshot? {
        guard AXIsProcessTrusted() else { return nil }

        let ws = NSWorkspace.shared
        let front = ws.frontmostApplication
        let appName = front?.localizedName ?? ""
        let bundleId = front?.bundleIdentifier ?? ""
        let pid = front?.processIdentifier ?? 0

        let sys = AXUIElementCreateSystemWide()
        guard let element = axCopy(sys, kAXFocusedUIElementAttribute) as! AXUIElement? else {
            return nil
        }

        let role = (axCopy(element, kAXRoleAttribute) as? String) ?? ""
        let identifier = (axCopy(element, kAXIdentifierAttribute) as? String) ?? ""
        let windowTitle = focusedWindowTitle(for: element) ?? ""
        let value = (axCopy(element, kAXValueAttribute) as? String) ?? ""
        let editable = isElementEditable(element, role: role)

        var location = 0
        var length = 0
        if let rangeRef = axCopy(element, kAXSelectedTextRangeAttribute) {
            let axVal = rangeRef as! AXValue
            var range = CFRange()
            if AXValueGetValue(axVal, .cfRange, &range) {
                location = max(0, range.location)
                length = max(0, range.length)
            }
        }

        // The AX selection range is in UTF-16 code units, which is also
        // NSString's index space; Character offsets would drift after the
        // first emoji or other non-BMP character.
        //
        // Editors and terminals expose their whole buffer as the value. Only
        // a window around the cursor is kept, so a poll costs O(window)
        // rather than O(document).
        let full = value as NSString
        let safeLoc = min(location, full.length)
        let safeEnd = min(safeLoc + length, full.length)
        let windowStart = full.rangeOfComposedCharacterSequence(at: max(0, safeLoc - fieldWindow)).location
        let windowEndRaw = min(full.length, safeEnd + fieldWindow)
        let windowEnd = windowEndRaw < full.length
            ? full.rangeOfComposedCharacterSequence(at: windowEndRaw).location
            : full.length
        let before = full.substring(with: NSRange(location: windowStart, length: safeLoc - windowStart))
        let selected = full.substring(with: NSRange(location: safeLoc, length: safeEnd - safeLoc))
        let after = full.substring(with: NSRange(location: safeEnd, length: max(0, windowEnd - safeEnd)))
        let windowed = before + selected + after

        return FocusedSnapshot(
            appName: appName,
            bundleId: bundleId,
            pid: pid,
            role: role,
            identifier: identifier,
            windowTitle: windowTitle,
            fullFieldContent: windowed,
            textBeforeCursor: before,
            textAfterCursor: after,
            selectedText: selected,
            isEditable: editable
        )
    }

    /// Walk the focused window's AX tree and collect **only content text** —
    /// static labels, headings, multi-line text areas — up to `maxVisibleChars`.
    /// We deliberately skip button titles, menu items, toolbar labels, icon
    /// descriptions, and other UI chrome: those produce noisy hotwords like
    /// "Close", "Sidebar", "New Message" that aren't what the user is
    /// actually reading.
    ///
    ///
    /// The target app is passed in (captured on the main thread when the
    /// recording starts) so this can run on a background queue: the walk is
    /// one synchronous IPC round-trip per attribute, and a slow or hung
    /// target app must not stall the main thread. `timeBudget` bounds the
    /// whole walk; whatever was collected by then is returned.
    static func captureAmbient(
        pid: pid_t,
        bundleId: String,
        appName: String,
        maxVisibleChars: Int = 2500,
        timeBudget: TimeInterval = 0.4
    ) -> AmbientSnapshot? {
        guard AXIsProcessTrusted(), pid != 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeBudget)

        let appElement = AXUIElementCreateApplication(pid)
        // Bound each IPC call; the default is several seconds.
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let window = axCopy(appElement, kAXFocusedWindowAttribute) as! AXUIElement? else {
            return nil
        }
        let title = (axCopy(window, kAXTitleAttribute) as? String) ?? ""

        var collected: [String] = []
        var seen = Set<String>()
        var charCount = 0
        var nodeCount = 0

        walkAX(window, depth: 0, maxDepth: 16, maxNodes: 1500, deadline: deadline, nodeCount: &nodeCount) { text in
            guard charCount < maxVisibleChars else { return false }
            // A single text area can hold a whole document; only its head
            // can end up in the snapshot anyway.
            let trimmed = String(text.prefix(maxVisibleChars)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return true }
            if seen.contains(trimmed) { return true }
            seen.insert(trimmed)
            collected.append(trimmed)
            charCount += trimmed.count + 1
            return charCount < maxVisibleChars
        }

        let joined = collected.joined(separator: "\n").prefix(maxVisibleChars)
        return AmbientSnapshot(
            bundleId: bundleId,
            appName: appName,
            windowTitle: title,
            visibleWindowText: String(joined)
        )
    }

    // MARK: - Helpers

    /// Roles whose `AXValue` represents actual on-screen content the user
    /// is reading. Anything else (buttons, menu items, toolbars, rows,
    /// groups, images...) is structural and contributes noise.
    private static let contentTextRoles: Set<String> = [
        "AXStaticText",
        "AXText",
        "AXHeading",
        "AXTextArea",
        "AXCell",         // some tables expose the cell's text directly as its value
    ]

    /// DFS walk of the AX tree, emitting content-text values only. Children
    /// of non-text elements are still traversed (that's how we reach the
    /// `AXStaticText` nodes inside rows, cells, groups, web areas, etc.).
    private static func walkAX(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        deadline: Date,
        nodeCount: inout Int,
        emit: (String) -> Bool
    ) {
        if depth > maxDepth || nodeCount >= maxNodes || Date() >= deadline { return }
        nodeCount += 1

        let role = (axCopy(element, kAXRoleAttribute) as? String) ?? ""
        // Skip secure text fields outright — their AXValue is usually masked
        // or sensitive (passwords, OTPs). Nothing to learn from here anyway.
        let subrole = (axCopy(element, kAXSubroleAttribute) as? String) ?? ""
        if subrole == "AXSecureTextField" { return }

        if contentTextRoles.contains(role) {
            if let s = axCopy(element, kAXValueAttribute) as? String, !s.isEmpty {
                if !emit(s) { return }
            }
        }

        if let kids = axCopy(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in kids {
                walkAX(child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, deadline: deadline, nodeCount: &nodeCount, emit: emit)
                if nodeCount >= maxNodes || Date() >= deadline { return }
            }
        }
    }

    private static func axCopy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        return err == .success ? ref : nil
    }

    private static func focusedWindowTitle(for element: AXUIElement) -> String? {
        // Walk up to the window and read its title.
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let e = current else { return nil }
            let role = (axCopy(e, kAXRoleAttribute) as? String) ?? ""
            if role == kAXWindowRole {
                return axCopy(e, kAXTitleAttribute) as? String
            }
            current = axCopy(e, kAXParentAttribute) as! AXUIElement?
        }
        return nil
    }

    private static func isElementEditable(_ element: AXUIElement, role: String) -> Bool {
        // Heuristic matching Typeless's `is_editable` calculation: classic
        // editable roles, or the element has a settable kAXValueAttribute.
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        if editableRoles.contains(role) { return true }

        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if err == .success, settable.boolValue { return true }

        // Browsers & Electron apps often expose an AXTextArea-like role
        // indirectly; fall back to "has a string value" as a weak proxy.
        if (axCopy(element, kAXValueAttribute) as? String) != nil {
            return true
        }
        return false
    }
}
