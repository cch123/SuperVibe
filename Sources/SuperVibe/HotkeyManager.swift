import Cocoa

final class HotkeyManager {

    var onToggleRecord: (() -> Void)?
    var onToggleTranslate: (() -> Void)?
    var onCancel: (() -> Void)?

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false
    /// Set when Right Option was used as a modifier for another key while
    /// held (Option+/ for translate, or Option+E etc. to type a character).
    /// A release then must not toggle recording.
    private var chordUsed = false

    func start() {
        if AXIsProcessTrusted() {
            log("[Hotkey] Accessibility permission OK")
        } else {
            log("[Hotkey] WARNING: Accessibility not granted. Global hotkey won't work.")
            log("[Hotkey] Grant in: System Settings -> Privacy & Security -> Accessibility")
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
            return e
        }

        // Use CGEventTap to intercept key events globally, so we can suppress
        // the ÷ character that macOS produces for Option+/
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("[Hotkey] Failed to create CGEventTap – falling back to passive monitors")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        log("[Hotkey] Listening (Right Option = transcribe, Right Option+/ = translate, ESC = cancel)")
    }

    func stop() {
        [globalFlagsMonitor, localFlagsMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
    }

    deinit { stop() }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == 61 else { return } // Right Option
        let optionDown = event.modifierFlags.contains(.option)
        if optionDown && !isKeyDown {
            isKeyDown = true
            chordUsed = false
        } else if !optionDown && isKeyDown {
            isKeyDown = false
            if !chordUsed {
                log("[Hotkey] Right Option UP -> toggle record")
                onToggleRecord?()
            }
            chordUsed = false
        }
    }

    /// Called from the CGEventTap callback. Returns `true` if the event
    /// should be suppressed (consumed).
    fileprivate func handleKeyTap(_ keyCode: Int64) -> Bool {
        if keyCode == 53 { // ESC
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            return false // let ESC propagate normally
        }
        guard isKeyDown else { return false }
        if keyCode == 44 { // / while Right Option held
            guard !chordUsed else { return true } // key repeat of the same chord
            chordUsed = true
            log("[Hotkey] Right Option + / -> toggle translate")
            DispatchQueue.main.async { [weak self] in self?.onToggleTranslate?() }
            return true // suppress the ÷ character
        }
        // Right Option is being used to type a character (Option+E, ...).
        chordUsed = true
        return false
    }
}

/// Top-level C-compatible callback for the CGEventTap.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // If the tap is disabled by the system, re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    if manager.handleKeyTap(keyCode) {
        return nil // suppress the event
    }
    return Unmanaged.passUnretained(event)
}
