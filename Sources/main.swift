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

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupGlobalHotkey()
        audioRecorder = AudioRecorder()
        checkPermissions()
        ensureDaemonRunning()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "VoiceInput (Option+Shift+V)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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

    private func setupGlobalHotkey() {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x56494E50), id: 1) // "VINP"
        // Option+Shift+V: modifiers optionKey=0x0800, shiftKey=0x0200; V keycode=9
        let modifiers: UInt32 = UInt32(optionKey | shiftKey)
        let status = RegisterEventHotKey(9, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            debugLog(" Failed to register hotkey (status: \(status))")
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            let app = NSApplication.shared.delegate as! AppDelegate
            DispatchQueue.main.async { app.toggleRecording() }
            return noErr
        }, 1, &eventType, nil, nil)

        debugLog(" Hotkey Option+Shift+V registered successfully (no Accessibility needed)")
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
