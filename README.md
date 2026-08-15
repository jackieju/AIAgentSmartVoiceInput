# AIAgentSmartVoiceInput

macOS voice input tool. Press a hotkey to record, automatically transcribe and paste into the current terminal (e.g. opencode).

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)
- whisper.cpp (`brew install whisper-cpp`)
- Whisper model file

## Installation

### Option A: Homebrew (recommended)

```bash
brew tap jackieju/tools
brew install ai-agent-smart-voice-input
```

### Option B: Build from source

```bash
cd AIAgentSmartVoiceInput
swift build
cp .build/debug/VoiceInput VoiceInput.app/Contents/MacOS/VoiceInput
codesign -s - --force --deep --entitlements VoiceInput.entitlements VoiceInput.app

swiftc -o inject-helper inject-helper.swift \
  -framework AppKit -framework CoreGraphics -framework Carbon
```

### Download Whisper Model

```bash
mkdir -p ~/.local/share/whisper-cpp/models
curl -L -o ~/.local/share/whisper-cpp/models/ggml-large-v3-turbo.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
```

Mirror (for users in China):
```bash
curl -L -o ~/.local/share/whisper-cpp/models/ggml-large-v3-turbo.bin \
  "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
```

### Permissions

In System Settings → Privacy & Security:

- **Microphone**: Add `VoiceInput.app`
- **Accessibility**: Add `inject-helper`

### Auto-start + Auto-restart

```bash
cp com.voiceinput.app.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.voiceinput.app.plist
```

VoiceInput will start on login and auto-restart if force-quit.

To disable auto-restart:
```bash
launchctl unload ~/Library/LaunchAgents/com.voiceinput.app.plist
```

## Usage

```bash
# Launch (automatically starts inject-helper daemon in a new Terminal tab)
open VoiceInput.app
```

Default hotkey: **Cmd+5** (configurable in Settings)

- First press: Start recording (menu bar icon changes to 🔴)
- Second press: Stop recording, transcribe, auto-paste into terminal and press Enter
- Press **Escape** during recording: Cancel, do nothing

## Architecture

```
VoiceInput.app          inject-helper --daemon
┌─────────────┐         ┌──────────────────┐
│ Global Hotkey │         │ Poll /tmp file    │
│ Record(AVAudio)│        │ On text detected: │
│ Transcribe    │──write─▶│  Cmd+V paste      │
│ Write trigger │  /tmp/  │  Enter to send    │
└─────────────┘         └──────────────────┘
```

VoiceInput.app handles hotkey, recording, and transcription, writing the result to `/tmp/voiceinput_inject.txt`.
inject-helper daemon runs in Terminal (with Accessibility permission), polls the file, and injects text via CGEvent (Cmd+V + Enter).

## Manually Start Daemon

If the daemon didn't start automatically:

```bash
./inject-helper --daemon
```

## Troubleshooting

- View debug log: `cat /tmp/voiceinput_debug.log`
- Check if daemon is running: `pgrep -f "inject-helper --daemon"`
- Ensure inject-helper has Accessibility permission
- Ensure VoiceInput.app has Microphone permission

## License

Copyright (C) 2026 Jackie Ju

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.
