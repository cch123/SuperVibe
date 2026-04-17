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

        let chars = Array(value)
        let safeLoc = min(location, chars.count)
        let safeEnd = min(safeLoc + length, chars.count)
        let before = String(chars[..<safeLoc])
        let selected = String(chars[safeLoc..<safeEnd])
        let after = String(chars[safeEnd...])

        return FocusedSnapshot(
            appName: appName,
            bundleId: bundleId,
            pid: pid,
            role: role,
            identifier: identifier,
            windowTitle: windowTitle,
            fullFieldContent: value,
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
    /// Strings contained in `excluding` are skipped so we don't echo back
    /// the user's own focused-field content.
    static func captureAmbient(maxVisibleChars: Int = 2500, excluding: String = "") -> AmbientSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        let bundleId = front?.bundleIdentifier ?? ""
        let appName = front?.localizedName ?? ""
        let pid = front?.processIdentifier ?? 0
        guard pid != 0 else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        guard let window = axCopy(appElement, kAXFocusedWindowAttribute) as! AXUIElement? else {
            return nil
        }
        let title = (axCopy(window, kAXTitleAttribute) as? String) ?? ""

        var collected: [String] = []
        var seen = Set<String>()
        var charCount = 0
        var nodeCount = 0
        let excludeTrim = excluding.trimmingCharacters(in: .whitespacesAndNewlines)

        walkAX(window, depth: 0, maxDepth: 16, maxNodes: 1500, nodeCount: &nodeCount) { text in
            guard charCount < maxVisibleChars else { return false }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return true }
            // Skip the focused field's own value (avoid echoing it back).
            if !excludeTrim.isEmpty, trimmed == excludeTrim { return true }
            if !excludeTrim.isEmpty, excludeTrim.contains(trimmed), trimmed.count > 24 { return true }
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
        nodeCount: inout Int,
        emit: (String) -> Bool
    ) {
        if depth > maxDepth || nodeCount >= maxNodes { return }
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
                walkAX(child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, nodeCount: &nodeCount, emit: emit)
                if nodeCount >= maxNodes { return }
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
