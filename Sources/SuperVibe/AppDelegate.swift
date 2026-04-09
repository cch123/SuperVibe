import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let appState = AppState()
    private var accessibilityTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        requestPermissions()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "SuperVibe"
            )
            button.image?.isTemplate = true
        }

        rebuildMenu()

        // Observe recording state to update icon
        appState.onRecordingChanged = { [weak self] isRecording in
            DispatchQueue.main.async {
                self?.statusItem.button?.image = NSImage(
                    systemSymbolName: isRecording ? "waveform.circle.fill" : "waveform",
                    accessibilityDescription: "SuperVibe"
                )
                self?.rebuildMenu()
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Record toggle
        let recordTitle = appState.isRecording ? "Stop Recording" : "Start Recording"
        let recordItem = NSMenuItem(title: recordTitle, action: #selector(toggleRecord), keyEquivalent: "r")
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(.separator())

        // Polishing
        let polishItem = NSMenuItem(title: "Polishing (GPT)", action: #selector(togglePolish), keyEquivalent: "")
        polishItem.target = self
        polishItem.state = appState.postprocessEnabled ? .on : .off
        menu.addItem(polishItem)

        // Translation submenu
        let transMenu = NSMenu()
        for (label, code) in [
            ("Off", nil), ("English", "en"), ("Chinese", "zh"),
            ("Japanese", "ja"), ("Korean", "ko"), ("French", "fr"),
            ("Spanish", "es"), ("German", "de"),
        ] as [(String, String?)] {
            let item = NSMenuItem(title: label, action: #selector(setTranslation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = appState.translationLanguage == code ? .on : .off
            transMenu.addItem(item)
        }
        let transItem = NSMenuItem(title: "Translation", action: nil, keyEquivalent: "")
        transItem.submenu = transMenu
        menu.addItem(transItem)

        menu.addItem(.separator())

        // Status
        let statusItem = NSMenuItem(title: appState.statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // Hotkey hint
        let hint = NSMenuItem(title: "Right Option: toggle recording", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - Permissions

    private func requestPermissions() {
        if AXIsProcessTrusted() {
            log("[SuperVibe] Accessibility OK")
        } else {
            log("[SuperVibe] WARNING: Accessibility not granted – global hotkey may not work")
            log("[SuperVibe] Grant in: System Settings -> Privacy & Security -> Accessibility")
        }
        // Always start hotkeys – global monitor silently no-ops without permission
        appState.setupHotkeys()
    }

    // MARK: - Actions

    @objc private func toggleRecord() {
        appState.toggleRecording()
    }

    @objc private func togglePolish() {
        appState.postprocessEnabled.toggle()
        log("[SuperVibe] Polishing: \(appState.postprocessEnabled)")
        rebuildMenu()
    }

    @objc private func setTranslation(_ sender: NSMenuItem) {
        appState.translationLanguage = sender.representedObject as? String
        log("[SuperVibe] Translation: \(appState.translationLanguage ?? "off")")
        rebuildMenu()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
