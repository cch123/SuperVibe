import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        requestPermissions()

        // Check VibeVoice availability in background
        appState.checkVibeVoiceAvailability()

        // Warmup VibeVoice if it's the selected engine
        if appState.engineMode == .vibeVoice {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                try? self?.appState.vibeVoice.warmup()
            }
        }
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

        appState.onConfigChanged = { [weak self] in
            DispatchQueue.main.async {
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
            menu.addItem(shortcutMenuItem("Transcribe", shortcut: "Right \u{2325}", action: #selector(toggleRecord)))
            let translateItem = shortcutMenuItem("Translate", shortcut: "Right \u{2325} /", action: #selector(toggleTranslateRecord))
            if appState.translationLanguage == nil {
                translateItem.isEnabled = false
            }
            menu.addItem(translateItem)
        }

        menu.addItem(.separator())

        // Engine selection submenu
        let engineMenu = NSMenu()

        let cloudItem = NSMenuItem(title: "Cloud Pipeline", action: #selector(selectCloudEngine), keyEquivalent: "")
        cloudItem.target = self
        cloudItem.state = appState.engineMode == .cloud ? .on : .off
        engineMenu.addItem(cloudItem)

        let vibeItem = NSMenuItem(title: "VibeVoice (Local)", action: #selector(selectVibeVoiceEngine), keyEquivalent: "")
        vibeItem.target = self
        vibeItem.state = appState.engineMode == .vibeVoice ? .on : .off
        if !appState.vibeVoiceAvailable {
            vibeItem.title = "VibeVoice (not installed)"
            vibeItem.isEnabled = false
        }
        engineMenu.addItem(vibeItem)

        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        if appState.engineMode == .vibeVoice {
            engineItem.title = "Engine (VibeVoice)"
        }
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        // VibeVoice model submenu (only when VibeVoice is selected)
        if appState.engineMode == .vibeVoice {
            let modelMenu = NSMenu()
            for model in VibeVoiceSTT.availableModels {
                let item = NSMenuItem(title: model.name, action: #selector(selectVibeModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = model.id
                item.state = model.id == appState.vibeVoice.currentModel.id ? .on : .off
                modelMenu.addItem(item)
            }
            let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
            modelItem.submenu = modelMenu
            menu.addItem(modelItem)
        }

        menu.addItem(.separator())

        // Polish toggle
        let polishItem = NSMenuItem(title: "Polish", action: #selector(togglePolish), keyEquivalent: "")
        polishItem.target = self
        polishItem.state = appState.polishEnabled ? .on : .off
        menu.addItem(polishItem)

        // Translation submenu
        let transMenu = NSMenu()
        let languages: [(String, String?)] = [
            ("Off", nil),
            ("English", "en"),
            ("Chinese (Simplified)", "zh"),
            ("Chinese (Traditional)", "zh-TW"),
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

        // LLM settings (only for VibeVoice mode)
        if appState.engineMode == .vibeVoice {
            menu.addItem(.separator())

            // LLM Provider submenu
            let providerMenu = NSMenu()
            let claudeProviderItem = NSMenuItem(title: "Claude (Anthropic)", action: #selector(selectClaudeProvider), keyEquivalent: "")
            claudeProviderItem.target = self
            claudeProviderItem.state = appState.llmProvider == .claude ? .on : .off
            providerMenu.addItem(claudeProviderItem)

            let geminiProviderItem = NSMenuItem(title: "Gemini (Google)", action: #selector(selectGeminiProvider), keyEquivalent: "")
            geminiProviderItem.target = self
            geminiProviderItem.state = appState.llmProvider == .gemini ? .on : .off
            providerMenu.addItem(geminiProviderItem)

            let providerLabel = appState.llmProvider == .claude ? "Claude" : "Gemini"
            let providerItem = NSMenuItem(title: "LLM Provider (\(providerLabel))", action: nil, keyEquivalent: "")
            providerItem.submenu = providerMenu
            menu.addItem(providerItem)

            // LLM model submenu (shows models for the current provider)
            let llmModelMenu = NSMenu()
            for model in appState.llmService.currentModels {
                let item = NSMenuItem(title: model.name, action: #selector(selectLLMModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = model.id
                item.state = model.id == appState.llmService.currentModel.id ? .on : .off
                llmModelMenu.addItem(item)
            }
            let llmModelItem = NSMenuItem(title: "LLM Model (\(appState.llmService.currentModel.name))", action: nil, keyEquivalent: "")
            llmModelItem.submenu = llmModelMenu
            menu.addItem(llmModelItem)

            // API Key
            let keyTitle = appState.llmService.isAvailable
                ? "LLM API Key (set)"
                : "Set LLM API Key..."
            let keyItem = NSMenuItem(title: keyTitle, action: #selector(setLLMApiKey), keyEquivalent: "")
            keyItem.target = self
            menu.addItem(keyItem)
        }

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

    private func shortcutMenuItem(_ title: String, shortcut: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self

        let pStyle = NSMutableParagraphStyle()
        pStyle.tabStops = [NSTextTab(textAlignment: .right, location: 180)]

        let str = NSMutableAttributedString(string: "\(title)\t\(shortcut)", attributes: [
            .font: NSFont.menuFont(ofSize: 14),
            .paragraphStyle: pStyle,
        ])
        str.addAttribute(
            .foregroundColor, value: NSColor.secondaryLabelColor,
            range: NSRange(location: title.count + 1, length: shortcut.count)
        )
        item.attributedTitle = str
        return item
    }

    @objc private func toggleRecord() {
        appState.toggleRecording()
    }

    @objc private func toggleTranslateRecord() {
        appState.toggleTranslateRecording()
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

    @objc private func togglePolish() {
        appState.polishEnabled.toggle()
        log("[SuperVibe] Polish: \(appState.polishEnabled ? "ON" : "OFF")")
        rebuildMenu()
    }

    @objc private func selectCloudEngine() {
        appState.setEngineMode(.cloud)
    }

    @objc private func selectVibeVoiceEngine() {
        appState.setEngineMode(.vibeVoice)
    }

    @objc private func selectVibeModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String,
              let model = VibeVoiceSTT.availableModels.first(where: { $0.id == modelId })
        else { return }
        appState.selectVibeModel(model)
    }

    @objc private func selectClaudeProvider() {
        appState.llmProvider = .claude
        log("[SuperVibe] LLM provider: Claude")
        rebuildMenu()
    }

    @objc private func selectGeminiProvider() {
        appState.llmProvider = .gemini
        log("[SuperVibe] LLM provider: Gemini")
        rebuildMenu()
    }

    @objc private func selectLLMModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else { return }

        if appState.llmProvider == .claude {
            guard let model = LLMService.claudeModels.first(where: { $0.id == modelId }) else { return }
            appState.llmService.selectedModel = model
        } else {
            guard let model = LLMService.geminiModels.first(where: { $0.id == modelId }) else { return }
            appState.llmService.selectedGeminiModel = model
        }
        appState.saveConfig()
        log("[SuperVibe] LLM model: \(appState.llmService.currentModel.name)")
        rebuildMenu()
    }

    @objc private func setLLMApiKey() {
        let alert = NSAlert()

        if appState.llmProvider == .claude {
            alert.messageText = "Claude API Key"
            alert.informativeText = "Enter your Anthropic API key.\nhttps://console.anthropic.com/settings/keys"
        } else {
            alert.messageText = "Gemini API Key"
            alert.informativeText = "Enter your Google Gemini API key.\nhttps://aistudio.google.com/apikey"
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        if appState.llmProvider == .claude {
            input.stringValue = appState.llmApiKey ?? ""
            input.placeholderString = "sk-ant-..."
        } else {
            input.stringValue = appState.geminiApiKey ?? ""
            input.placeholderString = "AIza..."
        }
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if appState.llmProvider == .claude {
                appState.llmApiKey = key.isEmpty ? nil : key
            } else {
                appState.geminiApiKey = key.isEmpty ? nil : key
            }
            rebuildMenu()
        }
    }

    @objc private func quit() {
        appState.vibeVoice.shutdown()
        NSApplication.shared.terminate(nil)
    }
}
