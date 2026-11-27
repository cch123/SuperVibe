# SuperVibe

A macOS menu bar app for voice-to-text input with optional polishing and translation. Speak naturally, and the transcribed (or translated) text is pasted into the active application.

Speech recognition runs locally on Apple Silicon with Microsoft's VibeVoice-ASR models through [mlx-audio](https://github.com/Blaizzy/mlx-audio). Audio never leaves the machine. Polishing and translation are optional and use an LLM API (Claude or Gemini) with your own key.

## Features

- **Streaming transcription** -- text appears in the overlay while you are still speaking; after you stop, only the last audio window is left to transcribe
- **Polish** -- an LLM removes filler words and false starts and fixes punctuation
- **Translation** -- translate speech into English, Chinese, Japanese, Korean, French, Spanish, or German
- **Hotwords** -- a personal dictionary (`~/.SuperVibe/hotwords.txt`) biases recognition toward your names and acronyms
- **Ambient context** -- terms visible in the focused window bias recognition and help the LLM disambiguate jargon (skipped for password managers and system settings)
- **Learns from corrections** -- small edits you make to pasted text are remembered per app and applied to later dictations
- **Global hotkeys** -- works system-wide, no need to focus the app

## Hotkeys

| Shortcut | Action |
|---|---|
| **Right Option** (press & release) | Start/stop transcription |
| **Right Option + /** | Start/stop translation (uses the language selected in the menu bar) |
| **ESC** | Cancel current session |

- Transcription mode shows **cyan** UI
- Translation mode shows **magenta** UI

## Requirements

- macOS 14.0+ on Apple Silicon
- `mlx-audio` 0.6.8 or later, installed with pipx: `pipx install mlx-audio`
- Microphone permission
- Accessibility permission (global hotkeys, paste, reading the focused window)
- For polish/translation: an Anthropic or Google Gemini API key (set from the menu)

## ASR models

Selected from the **ASR Model** menu. Weights are downloaded to the Hugging Face cache on first use.

| Model | Streaming | Memory after load | Peak while transcribing |
|---|---|---|---|
| Streaming 7B 4bit (default) | yes | 5.6 GB | 7.3 GB |
| Streaming 1.5B | yes | 4.5 GB | 7.5 GB |
| Streaming 7B bf16 | yes | not measured (17 GB of weights) | not measured |
| Long-form 4bit / bf16 | no (transcribes after you stop) | 5.7 GB / not measured | 6.7 GB / not measured |

Measured on an M5 Max. Streaming models process audio in 2.9 s chunks with 0.5 s of lookahead, so the first text appears about 3.5 s after you start speaking. They support Chinese, English, French, German, Italian, Japanese, Korean, Portuguese, Russian, and Spanish; the long-form models cover 50+ languages.

## Build & Run

```bash
make debug          # debug build, logs to the terminal
make bundle         # release build packaged as SuperVibe.app
make test           # unit tests
make test-asr WAV=/path/to/24kHz-mono-int16.wav   # end-to-end test against the real model
```

`make debug-prompt` additionally prints every LLM prompt. Set `SUPERVIBE_ASR_DEBUG=1` to log the raw model output of each audio chunk.

## Architecture

```
 microphone                                         Python: vibevoice_server.py
     │ 24 kHz mono Int16                             ┌──────────────────────────┐
     ▼                                               │ reader thread ─▶ queue   │
 AudioRecorder ──▶ VibeVoiceSTT ══ JSON lines ══════▶│ main thread: MLX model   │
                        ▲          over stdin/stdout │   one step per 2.9 s     │
                        │ delta / done / error  ◀════│   audio window           │
                        ▼                            └──────────────────────────┘
                    AppState ──▶ LLMService (polish / translate, optional)
                        │
                        ├──▶ OverlayPanel (live text, status)
                        └──▶ PasteService ──▶ EditTracker ──▶ CorrectionStore
```

| File | Role |
|---|---|
| `AppDelegate.swift` | Menu bar UI and status item |
| `AppState.swift` | Core state machine; orchestrates one dictation at a time |
| `VibeVoiceSTT.swift` | Client for the ASR server process: lifecycle, sessions, protocol |
| `Resources/vibevoice_server.py` | Persistent ASR server; keeps the model loaded |
| `AudioRecorder.swift` | Microphone capture, converted to 24 kHz mono PCM |
| `LLMService.swift` | Polish and translation through the Claude or Gemini API |
| `HotwordBuilder.swift` | Builds the hotword list from the user's dictionary, corrections, and screen text |
| `FocusedContext.swift` | Reads the focused app, window, and text field through the Accessibility API |
| `AppProfiles.swift` | Per-app prompt hints and the list of apps never read |
| `EditTracker.swift` / `CorrectionStore.swift` | Detect and persist the user's corrections to pasted text |
| `HotkeyManager.swift` | Global hotkey detection (Right Option, ESC) |
| `OverlayPanel.swift` | Floating overlay (SwiftUI + NSPanel) |
| `PasteService.swift` | Clipboard write + simulated Cmd+V paste |

## How It Works

1. The hotkey starts the microphone immediately. In parallel, the hotword list is collected from the user's dictionary, past corrections, and the focused window.
2. Audio is streamed to the ASR server. With a streaming model, the server emits a text delta for every audio chunk and the overlay shows it.
3. On stop, the server transcribes the remaining audio and returns the full text.
4. If polish or translation is enabled and an API key is set, the text goes through the LLM. If that request fails or is refused, the raw transcription is used.
5. The final text is pasted into the frontmost application via the clipboard.

## Files

Everything the app stores is in `~/.SuperVibe/`: `config.json` (settings and API keys, mode 0600), `hotwords.txt` (your dictionary), `corrections.jsonl` (learned corrections).
