import Cocoa

final class HotkeyManager {

    /// Right Option pressed (toggle).
    var onToggleRecord: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isKeyDown = false

    func start() {
        // Check accessibility permission (no prompt – just log)
        if AXIsProcessTrusted() {
            log("[Hotkey] Accessibility permission OK")
        } else {
            log("[Hotkey] WARNING: Accessibility not granted. Global hotkey won't work.")
            log("[Hotkey] Grant permission in: System Settings → Privacy & Security → Accessibility")
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
            return e
        }
        log("[Hotkey] Listening for Right Option")
    }

    func stop() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach { NSEvent.removeMonitor($0) }
        globalMonitor = nil
        localMonitor = nil
    }

    deinit { stop() }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == 61 else { return } // Right Option
        let optionDown = event.modifierFlags.contains(.option)
        if optionDown && !isKeyDown {
            isKeyDown = true
            log("[Hotkey] Right Option DOWN → toggle")
            onToggleRecord?()
        } else if !optionDown {
            isKeyDown = false
        }
    }
}
