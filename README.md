# SuperVibe

A macOS menu bar app for real-time voice-to-text input with optional translation. Speak naturally, and the transcribed (or translated) text is automatically pasted into the active application.

## Features

- **Voice Transcription** -- press a hotkey, speak, and the text is typed for you
- **Real-time Translation** -- translate speech into English, Chinese, Japanese, Korean, French, Spanish, or German
- **Cyberpunk Overlay UI** -- floating HUD with animated waveform bars, neon color coding, and scan-line aesthetics
- **Global Hotkeys** -- works system-wide, no need to focus the app

## Hotkeys

| Shortcut | Action |
|---|---|
| **Right Option** (press & release) | Start/stop transcription |
| **Right Option + /** | Start/stop translation (uses the language selected in the menu bar) |
| **ESC** | Cancel current session |

- Transcription mode shows **cyan** UI
- Translation mode shows **magenta** UI

## Menu Bar

Click the waveform icon in the menu bar to:

- Manually start/stop recording
- Select a translation target language (or turn translation off)
- Quit the app

## Requirements

- macOS 14.0+
- Microphone permission
- Accessibility permission (for global hotkeys)

## Build & Run

```bash
swift build
swift run
```

Or open in Xcode:

```bash
open Package.swift
```

## Architecture

| File | Role |
|---|---|
| `AppDelegate.swift` | Menu bar UI and status item |
| `AppState.swift` | Core state machine and pipeline orchestration |
| `HotkeyManager.swift` | Global hotkey detection (Right Option, ESC) |
| `OverlayPanel.swift` | Floating cyberpunk overlay (SwiftUI + NSPanel) |
| `PipelineClient.swift` | WebSocket client for the transcription/translation backend |
| `AudioRecorder.swift` | Microphone capture, downsampled to 16kHz mono PCM |
| `PasteService.swift` | Clipboard write + simulated Cmd+V paste |
| `Config.swift` | Pipeline stages and configuration constants |

## How It Works

1. User presses the hotkey to start recording
2. Audio is captured from the microphone and streamed over WebSocket to the backend
3. The backend returns ASR (speech-to-text) deltas in real time
4. If in translation mode, the backend also returns translated text after ASR completes
5. The final text is pasted into the frontmost application via the clipboard
