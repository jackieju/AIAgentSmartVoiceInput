import AppKit
import AVFoundation
import Carbon.HIToolbox
import os.log

private let logger = OSLog(subsystem: "com.voiceinput.app", category: "main")

private func debugLog(_ msg: String) {
    os_log("%{public}@", log: logger, type: .default, msg)
    let logFile = "/tmp/voiceinput_debug.log"
    let entry = "\(Date()): \(msg)\n"
    if let data = entry.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let fh = FileHandle(forWritingAtPath: logFile) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data)
        }
    }
}

@main
struct VoiceInputApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

extension UserDefaults {
    func contains(key: String) -> Bool {
        return object(forKey: key) != nil
    }
}

enum RecordingState {
    case idle
    case recording
    case transcribing
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var state: RecordingState = .idle
    private var audioRecorder: AudioRecorder?
    private var currentHotKeyRef: EventHotKeyRef?
    private var escHotKeyRef: EventHotKeyRef?
    private var hotkeyLabel: NSMenuItem!
    private var floatingButton: FloatingRecordButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerHotkey()
        audioRecorder = AudioRecorder()
        checkPermissions()
        ensureDaemonRunning()
        if !UserDefaults.standard.contains(key: "showFloatingButton") || UserDefaults.standard.bool(forKey: "showFloatingButton") {
            floatingButton = FloatingRecordButton(delegate: self)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "VoiceInput", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        hotkeyLabel = NSMenuItem(title: "  Hotkey: \(savedHotkeyDisplay())", action: nil, keyEquivalent: "")
        menu.addItem(hotkeyLabel)
        menu.addItem(NSMenuItem.separator())
        let showButtonItem = NSMenuItem(title: "Show Floating Button", action: #selector(toggleFloatingButton(_:)), keyEquivalent: "")
        showButtonItem.target = self
        showButtonItem.state = (!UserDefaults.standard.contains(key: "showFloatingButton") || UserDefaults.standard.bool(forKey: "showFloatingButton")) ? .on : .off
        menu.addItem(showButtonItem)
        let enlargeItem = NSMenuItem(title: "Enlarge Button", action: #selector(enlargeButton), keyEquivalent: "+")
        enlargeItem.target = self
        menu.addItem(enlargeItem)
        let shrinkItem = NSMenuItem(title: "Shrink Button", action: #selector(shrinkButton), keyEquivalent: "-")
        shrinkItem.target = self
        menu.addItem(shrinkItem)
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func toggleFloatingButton(_ sender: NSMenuItem) {
        let show = sender.state == .off
        sender.state = show ? .on : .off
        UserDefaults.standard.set(show, forKey: "showFloatingButton")
        if show {
            if floatingButton == nil {
                floatingButton = FloatingRecordButton(delegate: self)
            } else {
                floatingButton?.show()
            }
        } else {
            floatingButton?.hide()
        }
    }

    @objc private func enlargeButton() {
        floatingButton?.resize(by: 10)
    }

    @objc private func shrinkButton() {
        floatingButton?.resize(by: -10)
    }

    @objc private func showSuggestedHotkeys() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Suggested Hotkeys (No Conflicts)"
        window.center()

        let text = """
        Option + F keys (safest):
          Option+F1, Option+F2, Option+F3
          Option+F4, Option+F5, Option+F6
          Option+F7, Option+F8, Option+F9
          Option+F10, Option+F11, Option+F12

        Ctrl + F keys (F6-F12 safe):
          Ctrl+F6, Ctrl+F7, Ctrl+F8
          Ctrl+F9, Ctrl+F10, Ctrl+F11, Ctrl+F12
          (Ctrl+F1~F5 used by macOS)

        Cmd + F keys (F6-F12 mostly safe):
          Cmd+F6, Cmd+F7, Cmd+F8
          Cmd+F9, Cmd+F10, Cmd+F11, Cmd+F12
          (Cmd+F1~F5 may conflict with macOS)

        Cmd + number keys:
          Cmd+5, Cmd+6, Cmd+7, Cmd+8, Cmd+9
          (Cmd+1~4 often used by apps for tabs)

        Option + letter keys (all safe):
          Option+A through Option+Z
        """

        let textView = NSTextView(frame: NSRect(x: 15, y: 15, width: 310, height: 350))
        textView.string = text
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = .windowBackgroundColor

        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        objc_setAssociatedObject(NSApp!, "suggestedWindow", window, .OBJC_ASSOCIATION_RETAIN)
    }

    @objc private func openSettings() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInput Settings"
        window.center()

        let contentView = NSView(frame: window.contentView!.bounds)

        var y = 395

        let hotkeyTitle = NSTextField(labelWithString: "Hotkey:")
        hotkeyTitle.frame = NSRect(x: 20, y: y, width: 320, height: 18)
        hotkeyTitle.font = NSFont.boldSystemFont(ofSize: 12)
        contentView.addSubview(hotkeyTitle)
        y -= 30

        let keyField = HotkeyField(frame: NSRect(x: 20, y: y, width: 320, height: 28))
        keyField.isEditable = false
        keyField.alignment = .center
        keyField.font = NSFont.systemFont(ofSize: 14)
        keyField.stringValue = savedHotkeyDisplay()

        let conflictLabel = NSTextField(labelWithString: "")
        conflictLabel.frame = NSRect(x: 20, y: y - 18, width: 320, height: 16)
        conflictLabel.font = NSFont.systemFont(ofSize: 10)
        conflictLabel.textColor = .systemRed
        contentView.addSubview(conflictLabel)

        keyField.onHotkeyCapture = { [weak self] keyCode, modifiers, display in
            let conflict = self?.checkHotkeyConflict(keyCode: keyCode, modifiers: modifiers)
            if let conflict = conflict {
                conflictLabel.stringValue = "⚠️ Conflict: \(conflict)"
                keyField.stringValue = "\(display) ⚠️"
            } else {
                conflictLabel.stringValue = ""
                keyField.stringValue = display
            }
            UserDefaults.standard.set(Int(keyCode), forKey: "hotkeyKeyCode")
            UserDefaults.standard.set(Int(modifiers), forKey: "hotkeyModifiers")
            UserDefaults.standard.set(display, forKey: "hotkeyDisplay")
            self?.registerHotkey()
            self?.hotkeyLabel.title = "  Hotkey: \(display)"
        }
        contentView.addSubview(keyField)

        let suggestBtn = NSButton(frame: NSRect(x: 220, y: y - 20, width: 120, height: 20))
        suggestBtn.title = "Suggested Hotkeys"
        suggestBtn.bezelStyle = .inline
        suggestBtn.font = NSFont.systemFont(ofSize: 11)
        suggestBtn.target = self
        suggestBtn.action = #selector(showSuggestedHotkeys)
        contentView.addSubview(suggestBtn)

        y -= 50

        let providerTitle = NSTextField(labelWithString: "Transcription Provider:")
        providerTitle.frame = NSRect(x: 20, y: y, width: 320, height: 18)
        providerTitle.font = NSFont.boldSystemFont(ofSize: 12)
        contentView.addSubview(providerTitle)
        y -= 28

        let providerPopup = NSPopUpButton(frame: NSRect(x: 20, y: y, width: 320, height: 26))
        providerPopup.addItems(withTitles: ["Local (whisper-cpp)", "OpenAI Whisper API", "Groq Whisper API"])
        let savedProvider = UserDefaults.standard.integer(forKey: "transcriptionProvider")
        providerPopup.selectItem(at: savedProvider)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        contentView.addSubview(providerPopup)
        y -= 35

        let apiKeyTitle = NSTextField(labelWithString: "API Key:")
        apiKeyTitle.frame = NSRect(x: 20, y: y, width: 320, height: 18)
        apiKeyTitle.font = NSFont.boldSystemFont(ofSize: 12)
        contentView.addSubview(apiKeyTitle)
        y -= 26

        let apiKeyField = NSSecureTextField(frame: NSRect(x: 20, y: y, width: 320, height: 24))
        apiKeyField.placeholderString = "sk-... (required for OpenAI/Groq)"
        apiKeyField.stringValue = UserDefaults.standard.string(forKey: "apiKey") ?? ""
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyChanged(_:))
        contentView.addSubview(apiKeyField)
        y -= 22

        let apiHint = NSTextField(labelWithString: "Not needed for Local mode.")
        apiHint.frame = NSRect(x: 20, y: y, width: 320, height: 16)
        apiHint.font = NSFont.systemFont(ofSize: 10)
        apiHint.textColor = .secondaryLabelColor
        contentView.addSubview(apiHint)
        y -= 30

        let langTitle = NSTextField(labelWithString: "Recognition Language (select one for best accuracy):")
        langTitle.frame = NSRect(x: 20, y: y, width: 320, height: 18)
        langTitle.font = NSFont.boldSystemFont(ofSize: 12)
        contentView.addSubview(langTitle)
        y -= 28

        let languages = ["zh", "en", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "ar", "hi", "th", "vi"]
        let langNames = ["Chinese", "English", "Japanese", "Korean", "French", "German", "Spanish", "Italian", "Portuguese", "Russian", "Arabic", "Hindi", "Thai", "Vietnamese"]
        let savedLangs = UserDefaults.standard.stringArray(forKey: "selectedLanguages") ?? []

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: y - 70, width: 320, height: 80))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let langList = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: CGFloat(languages.count * 20)))

        for (i, lang) in languages.enumerated() {
            let cb = NSButton(checkboxWithTitle: langNames[i], target: self, action: #selector(langCheckboxChanged(_:)))
            cb.frame = NSRect(x: 4, y: langList.frame.height - CGFloat((i + 1) * 20), width: 280, height: 18)
            cb.tag = i
            cb.state = savedLangs.contains(lang) ? .on : .off
            langList.addSubview(cb)
        }
        scrollView.documentView = langList
        contentView.addSubview(scrollView)

        let langHint = NSTextField(labelWithString: "Select one = force that language. Multiple or none = auto detect.")
        langHint.frame = NSRect(x: 20, y: y - 88, width: 320, height: 14)
        langHint.font = NSFont.systemFont(ofSize: 10)
        langHint.textColor = .secondaryLabelColor
        contentView.addSubview(langHint)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        
        objc_setAssociatedObject(NSApp!, "settingsWindow", window, .OBJC_ASSOCIATION_RETAIN)
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "transcriptionProvider")
        debugLog("Provider changed to: \(sender.titleOfSelectedItem ?? "")")
    }

    @objc private func langCheckboxChanged(_ sender: NSButton) {
        let languages = ["zh", "en", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "ar", "hi", "th", "vi"]
        var saved = UserDefaults.standard.stringArray(forKey: "selectedLanguages") ?? []
        let lang = languages[sender.tag]

        if sender.state == .on {
            if !saved.contains(lang) { saved.append(lang) }
        } else {
            saved.removeAll { $0 == lang }
        }
        UserDefaults.standard.set(saved, forKey: "selectedLanguages")
        debugLog("Languages: \(saved)")
    }

    @objc private func apiKeyChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(sender.stringValue, forKey: "apiKey")
    }

    private func checkHotkeyConflict(keyCode: UInt32, modifiers: UInt32) -> String? {
        let knownConflicts: [(UInt32, UInt32, String)] = [
            (UInt32(kVK_F1), UInt32(controlKey), "macOS Keyboard Navigation"),
            (UInt32(kVK_F1), UInt32(cmdKey), "macOS Menu Bar Focus"),
            (UInt32(kVK_F2), UInt32(controlKey), "macOS Menu Bar Focus"),
            (UInt32(kVK_F3), UInt32(controlKey), "macOS Mission Control"),
            (UInt32(kVK_F4), UInt32(controlKey), "macOS App Windows"),
            (UInt32(kVK_F5), UInt32(controlKey), "macOS Voice Over"),
            (UInt32(kVK_Space), UInt32(cmdKey), "Spotlight"),
            (UInt32(kVK_Space), UInt32(cmdKey | optionKey), "Finder Search"),
            (UInt32(kVK_Tab), UInt32(cmdKey), "macOS App Switcher"),
            (UInt32(kVK_ANSI_Q), UInt32(cmdKey), "Quit Application"),
            (UInt32(kVK_ANSI_W), UInt32(cmdKey), "Close Window"),
            (UInt32(kVK_ANSI_H), UInt32(cmdKey), "Hide Application"),
            (UInt32(kVK_ANSI_M), UInt32(cmdKey), "Minimize Window"),
            (UInt32(kVK_ANSI_C), UInt32(cmdKey), "Copy"),
            (UInt32(kVK_ANSI_V), UInt32(cmdKey), "Paste"),
            (UInt32(kVK_ANSI_X), UInt32(cmdKey), "Cut"),
            (UInt32(kVK_ANSI_Z), UInt32(cmdKey), "Undo"),
            (UInt32(kVK_ANSI_A), UInt32(cmdKey), "Select All"),
        ]

        for (code, mods, desc) in knownConflicts {
            if keyCode == code && modifiers == mods {
                return desc
            }
        }

        var testRef: EventHotKeyRef?
        let testID = EventHotKeyID(signature: OSType(0x54455354), id: 99)
        let status = RegisterEventHotKey(keyCode, modifiers, testID, GetApplicationEventTarget(), 0, &testRef)
        if status != noErr {
            return "System shortcut (registration failed)"
        }
        if let ref = testRef {
            UnregisterEventHotKey(ref)
        }

        return nil
    }

    private func savedHotkeyDisplay() -> String {
        UserDefaults.standard.string(forKey: "hotkeyDisplay") ?? "Cmd+5"
    }

    private func registerHotkey() {
        if let existing = currentHotKeyRef {
            UnregisterEventHotKey(existing)
            currentHotKeyRef = nil
        }

        // Default: Cmd+5 (keycode 23 = kVK_ANSI_5)
        let keyCode: UInt32 = UInt32(UserDefaults.standard.integer(forKey: "hotkeyKeyCode") != 0
            ? UserDefaults.standard.integer(forKey: "hotkeyKeyCode") : kVK_ANSI_5)
        let modifiers: UInt32 = UInt32(UserDefaults.standard.integer(forKey: "hotkeyModifiers") != 0
            ? UserDefaults.standard.integer(forKey: "hotkeyModifiers") : cmdKey)

        let hotKeyID = EventHotKeyID(signature: OSType(0x56494E50), id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &currentHotKeyRef)
        if status != noErr {
            debugLog("Failed to register hotkey (status: \(status))")
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event!, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)

            let app = NSApplication.shared.delegate as! AppDelegate
            if hotkeyID.id == 2 {
                DispatchQueue.main.async { app.cancelRecording() }
            } else {
                DispatchQueue.main.async { app.toggleRecording() }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        debugLog("Hotkey \(savedHotkeyDisplay()) registered successfully")
    }

    private func cancelRecording() {
        guard state == .recording, let recorder = audioRecorder else { return }
        _ = recorder.stopRecording()
        unmuteSystemAudio()
        unregisterEscapeKey()
        state = .idle
        updateStatusIcon()
        debugLog("Recording cancelled by Escape")
    }

    private func registerEscapeKey() {
        let escID = EventHotKeyID(signature: OSType(0x56494E50), id: 2)
        RegisterEventHotKey(53, 0, escID, GetApplicationEventTarget(), 0, &escHotKeyRef)
    }

    private func unregisterEscapeKey() {
        if let ref = escHotKeyRef {
            UnregisterEventHotKey(ref)
            escHotKeyRef = nil
        }
    }

    private func saveTargetTTY() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"Terminal\" to return tty of selected tab of front window"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let tty = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !tty.isEmpty && tty != "missing value" {
            try? tty.write(toFile: "/tmp/voiceinput_target_tty.txt", atomically: false, encoding: .utf8)
            debugLog("Target TTY saved: \(tty)")
        } else {
            debugLog("Failed to get TTY from osascript")
        }
    }

    private var previousVolume: String?
    private var didPausePlayback = false

    private func muteSystemAudio() {
        let volProc = Process()
        volProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        volProc.arguments = ["-e", "output volume of (get volume settings)"]
        let pipe = Pipe()
        volProc.standardOutput = pipe
        volProc.standardError = FileHandle.nullDevice
        try? volProc.run()
        volProc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        previousVolume = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let mute = Process()
        mute.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        mute.arguments = ["-e", "set volume output volume 0"]
        try? mute.run()
        mute.waitUntilExit()

        simulateMediaKey(keyType: 16)
        didPausePlayback = true
        debugLog("Audio paused + muted (was vol \(previousVolume ?? "?"))")
    }

    private func unmuteSystemAudio() {
        if let vol = previousVolume, !vol.isEmpty {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "set volume output volume \(vol)"]
            try? proc.run()
            proc.waitUntilExit()
            previousVolume = nil
        }

        if didPausePlayback {
            simulateMediaKey(keyType: 16)
            didPausePlayback = false
        }
        debugLog("Audio resumed + volume restored")
    }

    private func simulateMediaKey(keyType: Int32) {
        let keyDown = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyType << 16) | (0xa << 8)),
            data2: -1
        )
        keyDown?.cgEvent?.post(tap: .cghidEventTap)

        let keyUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyType << 16) | (0xb << 8)),
            data2: -1
        )
        keyUp?.cgEvent?.post(tap: .cghidEventTap)
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        button.image = nil
        switch state {
        case .idle:
            button.title = "🎤"
        case .recording:
            button.title = "🔴"
        case .transcribing:
            button.title = "⏳"
        }
        floatingButton?.updateState(state)
    }

    func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        case .transcribing:
            break
        }
    }

    private func startRecording() {
        guard let recorder = audioRecorder else { return }

        saveTargetTTY()
        muteSystemAudio()
        registerEscapeKey()

        do {
            try recorder.startRecording()
            state = .recording
            updateStatusIcon()
            debugLog(" Recording started")
        } catch {
            debugLog(" Failed to start recording: \(error)")
            unmuteSystemAudio()
            unregisterEscapeKey()
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let recorder = audioRecorder else { return }
        let wavURL = recorder.stopRecording()
        unmuteSystemAudio()
        unregisterEscapeKey()
        state = .transcribing
        updateStatusIcon()
        debugLog(" Recording stopped, transcribing...")

        DispatchQueue.global(qos: .userInitiated).async {
            if !self.audioHasSpeech(wavURL: wavURL) {
                debugLog("Audio too quiet, likely no speech — skipping")
                DispatchQueue.main.async {
                    self.state = .idle
                    self.updateStatusIcon()
                }
                return
            }
            let text = self.transcribe(wavURL: wavURL)
            DispatchQueue.main.async {
                if let text = text, !text.isEmpty {
                    self.injectText(text)
                }
                self.state = .idle
                self.updateStatusIcon()
            }
        }
    }

    private func audioHasSpeech(wavURL: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: wavURL) else { return false }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return false }
        do { try file.read(into: buffer) } catch { return false }
        
        guard let channelData = buffer.floatChannelData?[0] else { return false }
        var sumSquares: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sumSquares += channelData[i] * channelData[i]
        }
        let rms = sqrt(sumSquares / Float(buffer.frameLength))
        debugLog("Audio RMS: \(rms)")
        return rms > 0.003
    }

    private func transcribe(wavURL: URL) -> String? {
        let provider = UserDefaults.standard.integer(forKey: "transcriptionProvider")
        var output: String?
        switch provider {
        case 1: output = transcribeViaAPI(wavURL: wavURL, provider: "openai")
        case 2: output = transcribeViaAPI(wavURL: wavURL, provider: "groq")
        default: output = transcribeLocal(wavURL: wavURL)
        }
        if let text = output {
            output = text.replacingOccurrences(of: "\\.$|。$", with: "", options: .regularExpression)
        }
        debugLog(" Transcribed: \(output ?? "")")
        return output
    }

    private func transcribeLocal(wavURL: URL) -> String? {
        let modelPath = NSString("~/.local/share/whisper-cpp/models").expandingTildeInPath
        let modelDir = URL(fileURLWithPath: modelPath)

        let preferredModels = [
            "ggml-large-v3-turbo.bin",
            "ggml-large-v3.bin",
            "ggml-medium.bin",
            "ggml-base.bin",
            "ggml-small.bin",
            "ggml-tiny.bin",
        ]

        var modelFile: URL?
        for name in preferredModels {
            let candidate = modelDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                modelFile = candidate
                break
            }
        }

        guard let model = modelFile else {
            debugLog(" No whisper model found in \(modelPath)")
            return nil
        }

        let whisperPath = "/opt/homebrew/bin/whisper-cli"
        guard FileManager.default.fileExists(atPath: whisperPath) else {
            debugLog(" whisper-cli not found at \(whisperPath)")
            return nil
        }

        let savedLangs = UserDefaults.standard.stringArray(forKey: "selectedLanguages") ?? []
        let langArg = savedLangs.isEmpty ? "auto" : savedLangs[0]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = [
            "-m", model.path,
            "-f", wavURL.path,
            "-l", langArg,
            "--no-timestamps",
            "-t", "4",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            debugLog(" whisper-cli failed: \(error)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeViaAPI(wavURL: URL, provider: String) -> String? {
        guard let apiKey = UserDefaults.standard.string(forKey: "apiKey"), !apiKey.isEmpty else {
            debugLog("API key not set")
            return nil
        }

        let endpoint: URL
        switch provider {
        case "groq":
            endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        default:
            endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        }

        guard let audioData = try? Data(contentsOf: wavURL) else {
            debugLog("Failed to read audio file")
            return nil
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append((provider == "groq" ? "whisper-large-v3-turbo" : "whisper-1").data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        debugLog("Calling \(provider) API...")
        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                debugLog("API error: \(error.localizedDescription)")
                return
            }
            guard let data = data else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                result = text
            } else {
                let raw = String(data: data, encoding: .utf8) ?? ""
                debugLog("API response parse failed: \(raw)")
            }
        }.resume()

        semaphore.wait()
        return result
    }

    private func injectText(_ text: String) {
        debugLog("Injecting text: \(text)")
        ensureDaemonRunning()
        let triggerFile = "/tmp/voiceinput_inject.txt"
        do {
            try text.write(toFile: triggerFile, atomically: false, encoding: .utf8)
            debugLog("Trigger file written")
        } catch {
            debugLog("Failed to write trigger file: \(error)")
        }
    }

    private func ensureDaemonRunning() {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-f", "inject-helper --daemon"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()
        
        if check.terminationStatus != 0 {
            let commandFile = URL(fileURLWithPath: "/Users/I027910/Desktop/ju/projects/AIAgentSmartVoiceInput/start-daemon.command")
            NSWorkspace.shared.open(commandFile)
            debugLog("Started inject-helper daemon via start-daemon.command")
        } else {
            debugLog("inject-helper daemon already running")
        }
    }

    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    debugLog(" Microphone permission denied")
                }
            }
        case .denied, .restricted:
            debugLog(" Microphone permission not granted")
            showPermissionAlert()
        default:
            break
        }
    }

    private func showPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "VoiceInput needs Microphone permission"
            alert.informativeText = "Please grant Microphone access in System Settings > Privacy & Security > Microphone"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var outputURL: URL

    init() {
        outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voiceinput_recording.wav")
    }

    func startRecording() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Convert to 16kHz mono for whisper
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "VoiceInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create target format"])
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "VoiceInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }

        // WAV output at 16kHz mono 16-bit
        let wavFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!
        outputFile = try AVAudioFile(forWriting: outputURL, settings: wavFormat.settings)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let file = self.outputFile else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil {
                try? file.write(from: convertedBuffer)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    func stopRecording() -> URL {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        outputFile = nil
        return outputURL
    }
}

class FloatingRecordButton {
    private var panel: NSPanel!
    private var button: DraggableButton!
    private weak var delegate: AppDelegate?
    private var trackingTimer: Timer?

    init(delegate: AppDelegate) {
        self.delegate = delegate
        setupPanel()
        startTracking()
    }

    private func setupPanel() {
        let size = CGFloat(UserDefaults.standard.double(forKey: "floatingButtonSize") > 0
            ? UserDefaults.standard.double(forKey: "floatingButtonSize") : 100)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let dragButton = DraggableButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        dragButton.title = "🎤"
        dragButton.onClick = { [weak self] in
            self?.delegate?.toggleRecording()
        }
        panel.contentView?.addSubview(dragButton)
        button = dragButton

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: screen.maxX - 120, y: screen.maxY - 120))
        panel.orderFrontRegardless()
    }

    func updateState(_ state: RecordingState) {
        switch state {
        case .idle:
            button.title = "🎤"
        case .recording:
            button.title = "🔴"
        case .transcribing:
            button.title = "⏳"
        }
        button.needsDisplay = true
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func resize(by delta: CGFloat) {
        var size = panel.frame.size.width + delta
        size = max(30, min(200, size))
        UserDefaults.standard.set(Double(size), forKey: "floatingButtonSize")
        let origin = panel.frame.origin
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: size, height: size), display: true)
        button.frame = NSRect(x: 0, y: 0, width: size, height: size)
        button.needsDisplay = true
    }

    private func startTracking() {
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.positionNearTerminal()
        }
    }

    private func positionNearTerminal() {
        guard let termApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }),
              termApp.isActive else {
            return
        }

        let appRef = AXUIElementCreateApplication(termApp.processIdentifier)
        var windowRef: AnyObject?
        AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard let window = windowRef else { return }

        var positionRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef)

        var position = CGPoint.zero
        var size = CGSize.zero
        if let posRef = positionRef {
            AXValueGetValue(posRef as! AXValue, .cgPoint, &position)
        }
        if let sRef = sizeRef {
            AXValueGetValue(sRef as! AXValue, .cgSize, &size)
        }

        guard size.width > 0 else { return }

        let screenHeight = NSScreen.main?.frame.height ?? 900
        let x = position.x + size.width - 54
        let y = screenHeight - position.y - 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

class DraggableButton: NSView {
    private var dragOrigin: NSPoint?
    private var isDragging = false
    var title: String = "🎤" { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        NSColor.black.withAlphaComponent(0.2).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        circle.lineWidth = 1.5
        circle.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: bounds.width * 0.45),
        ]
        let size = title.size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        title.draw(at: point, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let window = self.window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - origin.x
        let dy = current.y - origin.y

        if !isDragging && (abs(dx) > 3 || abs(dy) > 3) {
            isDragging = true
        }

        if isDragging {
            var frame = window.frame
            frame.origin.x += dx
            frame.origin.y += dy
            window.setFrameOrigin(frame.origin)
            dragOrigin = current
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            onClick?()
        }
        dragOrigin = nil
        isDragging = false
    }

    override var acceptsFirstResponder: Bool { true }
}

class HotkeyField: NSTextField {
    var onHotkeyCapture: ((UInt32, UInt32, String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.isEmpty { return }

        var parts: [String] = []
        var carbonModifiers: UInt32 = 0

        if flags.contains(.control) {
            parts.append("Ctrl")
            carbonModifiers |= UInt32(controlKey)
        }
        if flags.contains(.option) {
            parts.append("Option")
            carbonModifiers |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            parts.append("Shift")
            carbonModifiers |= UInt32(shiftKey)
        }
        if flags.contains(.command) {
            parts.append("Cmd")
            carbonModifiers |= UInt32(cmdKey)
        }

        let keyName = keyCodeToName(keyCode)
        parts.append(keyName)

        let display = parts.joined(separator: "+")
        onHotkeyCapture?(UInt32(keyCode), carbonModifiers, display)
    }

    private func keyCodeToName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Escape"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default: return "Key\(code)"
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyDown(with: event)
        return true
    }
}
