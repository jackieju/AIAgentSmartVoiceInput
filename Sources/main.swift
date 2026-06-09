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
    private var hotkeyLabel: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerHotkey()
        audioRecorder = AudioRecorder()
        checkPermissions()
        ensureDaemonRunning()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "VoiceInput", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let startItem = NSMenuItem(title: "Start Recording", action: #selector(menuStartRecording), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)
        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(menuStopRecording), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)
        menu.addItem(NSMenuItem.separator())
        hotkeyLabel = NSMenuItem(title: "  Hotkey: \(savedHotkeyDisplay())", action: nil, keyEquivalent: "")
        menu.addItem(hotkeyLabel)
        menu.addItem(NSMenuItem(title: "  Cancel: Escape", action: nil, keyEquivalent: ""))
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

    @objc private func menuStartRecording() {
        if state == .idle { startRecording() }
    }

    @objc private func menuStopRecording() {
        if state == .recording { stopRecordingAndTranscribe() }
    }

    @objc private func openSettings() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInput Settings"
        window.center()

        let contentView = NSView(frame: window.contentView!.bounds)

        let label = NSTextField(labelWithString: "Press new hotkey:")
        label.frame = NSRect(x: 20, y: 100, width: 320, height: 20)
        contentView.addSubview(label)

        let keyField = HotkeyField(frame: NSRect(x: 20, y: 60, width: 320, height: 30))
        keyField.isEditable = false
        keyField.alignment = .center
        keyField.font = NSFont.systemFont(ofSize: 16)
        keyField.stringValue = savedHotkeyDisplay()
        keyField.onHotkeyCapture = { [weak self] keyCode, modifiers, display in
            UserDefaults.standard.set(Int(keyCode), forKey: "hotkeyKeyCode")
            UserDefaults.standard.set(Int(modifiers), forKey: "hotkeyModifiers")
            UserDefaults.standard.set(display, forKey: "hotkeyDisplay")
            self?.registerHotkey()
            self?.hotkeyLabel.title = "  Hotkey: \(display)"
            keyField.stringValue = display
        }
        contentView.addSubview(keyField)

        let hint = NSTextField(labelWithString: "Click the field above, then press your desired hotkey combination.")
        hint.frame = NSRect(x: 20, y: 20, width: 320, height: 30)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        contentView.addSubview(hint)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        
        objc_setAssociatedObject(NSApp!, "settingsWindow", window, .OBJC_ASSOCIATION_RETAIN)
    }

    private func savedHotkeyDisplay() -> String {
        UserDefaults.standard.string(forKey: "hotkeyDisplay") ?? "Ctrl+F1"
    }

    private func registerHotkey() {
        if let existing = currentHotKeyRef {
            UnregisterEventHotKey(existing)
            currentHotKeyRef = nil
        }

        let keyCode: UInt32 = UInt32(UserDefaults.standard.integer(forKey: "hotkeyKeyCode") != 0
            ? UserDefaults.standard.integer(forKey: "hotkeyKeyCode") : 122)
        let modifiers: UInt32 = UInt32(UserDefaults.standard.integer(forKey: "hotkeyModifiers") != 0
            ? UserDefaults.standard.integer(forKey: "hotkeyModifiers") : controlKey)

        let hotKeyID = EventHotKeyID(signature: OSType(0x56494E50), id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &currentHotKeyRef)
        if status != noErr {
            debugLog("Failed to register hotkey (status: \(status))")
            return
        }

        // Escape key: keycode=53, no modifiers
        var escHotKeyRef: EventHotKeyRef?
        let escHotKeyID = EventHotKeyID(signature: OSType(0x56494E50), id: 2)
        RegisterEventHotKey(53, 0, escHotKeyID, GetApplicationEventTarget(), 0, &escHotKeyRef)

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
        state = .idle
        updateStatusIcon()
        debugLog("Recording cancelled by Escape")
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
    }

    private func toggleRecording() {
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
        do {
            try recorder.startRecording()
            state = .recording
            updateStatusIcon()
            debugLog(" Recording started")
        } catch {
            debugLog(" Failed to start recording: \(error)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let recorder = audioRecorder else { return }
        let wavURL = recorder.stopRecording()
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
        return rms > 0.005
    }

    private func transcribe(wavURL: URL) -> String? {
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = [
            "-m", model.path,
            "-f", wavURL.path,
            "-l", "auto",
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
        var output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = output {
            output = text.replacingOccurrences(of: "\\.$|。$", with: "", options: .regularExpression)
        }
        debugLog(" Transcribed: \(output ?? "")")
        return output
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
