import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let appState = AppState()

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
        if appState.isRecording {
            let stop = NSMenuItem(title: "Stop Recording", action: #selector(toggleRecord), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)

            let cancel = NSMenuItem(title: "Cancel (ESC)", action: #selector(cancelRecord), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        } else {
            let start = NSMenuItem(title: "Start Recording", action: #selector(toggleRecord), keyEquivalent: "")
            start.target = self
            menu.addItem(start)
        }

        menu.addItem(.separator())

        // Translation submenu
        let transMenu = NSMenu()
        let languages: [(String, String?)] = [
            ("Off", nil),
            ("English", "en"),
            ("Chinese", "zh"),
            ("Japanese", "ja"),
            ("Korean", "ko"),
            ("French", "fr"),
            ("Spanish", "es"),
            ("German", "de"),
        ]
        for (label, code) in languages {
            let item = NSMenuItem(title: label, action: #selector(setTranslation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = appState.translationLanguage == code ? .on : .off
            transMenu.addItem(item)
        }
        let transItem = NSMenuItem(title: "Translation", action: nil, keyEquivalent: "")
        if let lang = appState.translationLanguage {
            transItem.title = "Translation (\(lang.uppercased()))"
        }
        transItem.submenu = transMenu
        menu.addItem(transItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SuperVibe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - Permissions

    private func requestPermissions() {
        if AXIsProcessTrusted() {
            log("[SuperVibe] Accessibility OK")
        } else {
            log("[SuperVibe] WARNING: Accessibility not granted")
            log("[SuperVibe] Grant in: System Settings -> Privacy & Security -> Accessibility")
        }
        appState.setupHotkeys()
    }

    // MARK: - Actions

    @objc private func toggleRecord() {
        appState.toggleRecording()
    }

    @objc private func cancelRecord() {
        appState.cancelSession()
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
