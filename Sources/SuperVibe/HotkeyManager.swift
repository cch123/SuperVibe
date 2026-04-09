import Cocoa

final class HotkeyManager {

    var onToggleRecord: (() -> Void)?
    var onToggleTranslate: (() -> Void)?
    var onCancel: (() -> Void)?

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var isKeyDown = false
    private var slashHandled = false

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
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e)
            return e
        }
        log("[Hotkey] Listening (Right Option = transcribe, Right Option+/ = translate, ESC = cancel)")
    }

    func stop() {
        [globalFlagsMonitor, localFlagsMonitor, globalKeyMonitor, localKeyMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }

    deinit { stop() }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == 61 else { return } // Right Option
        let optionDown = event.modifierFlags.contains(.option)
        if optionDown && !isKeyDown {
            isKeyDown = true
            slashHandled = false
        } else if !optionDown && isKeyDown {
            isKeyDown = false
            if !slashHandled {
                log("[Hotkey] Right Option UP -> toggle record")
                onToggleRecord?()
            }
            slashHandled = false
        }
    }

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == 53 { // ESC
            log("[Hotkey] ESC -> cancel")
            onCancel?()
        } else if event.keyCode == 44 && isKeyDown && !slashHandled { // / while Right Option held
            slashHandled = true
            log("[Hotkey] Right Option + / -> toggle translate")
            onToggleTranslate?()
        }
    }
}
