import AVFoundation
import Speech
import AppKit
import Foundation

private func rtLog(_ msg: String) {
    let logFile = "/tmp/voiceinput_debug.log"
    let entry = "\(Date()): [RT] \(msg)\n"
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

class AudioRingBuffer {
    private var buffer: [Float]
    private var writeIndex = 0
    private var totalWritten: Int = 0
    private let capacity: Int
    private let lock = NSLock()

    init(seconds: Int = 30, sampleRate: Int = 16000) {
        capacity = seconds * sampleRate
        buffer = [Float](repeating: 0, count: capacity)
    }

    func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for sample in samples {
            buffer[writeIndex % capacity] = sample
            writeIndex += 1
        }
        totalWritten += samples.count
    }

    func slice(from startFrame: Int, to endFrame: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard endFrame > startFrame else { return nil }
        let count = endFrame - startFrame
        guard count > 0 && count <= capacity else { return nil }

        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let idx = (startFrame + i) % capacity
            result[i] = buffer[idx]
        }
        return result
    }

    var currentFrame: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeIndex
    }
}

enum RealtimeVoiceState {
    case idle
    case wakeListen
    case active
    case transcribing
}

class RealtimeVoiceMode {
    private var state: RealtimeVoiceState = .idle
    private var audioEngine: AVAudioEngine?
    private var ringBuffer: AudioRingBuffer
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var utteranceStartFrame: Int = 0
    private var sessionStartTime: Date?

    private var triggerKeywords: [String]
    private var exitKeywords: [String]
    private var wakeKeywords: [String]
    private var resetKeywords: [String]
    private var onSubmit: ((String) -> Void)?
    private var onStateChange: ((RealtimeVoiceState) -> Void)?

    var currentState: RealtimeVoiceState { state }

    init(triggerKeywords: [String] = ["发送", "回车", "enter"],
         exitKeywords: [String] = ["退出", "exit"],
         wakeKeywords: [String] = ["hey voice", "嘿语音"],
         resetKeywords: [String] = ["重来", "reset"],
         onSubmit: ((String) -> Void)? = nil,
         onStateChange: ((RealtimeVoiceState) -> Void)? = nil) {
        self.triggerKeywords = triggerKeywords
        self.exitKeywords = exitKeywords
        self.wakeKeywords = wakeKeywords
        self.resetKeywords = resetKeywords
        self.onSubmit = onSubmit
        self.onStateChange = onStateChange
        self.ringBuffer = AudioRingBuffer(seconds: 30, sampleRate: 16000)
    }

    func updateTriggerKeywords(_ keywords: [String]) { triggerKeywords = keywords }
    func updateExitKeywords(_ keywords: [String]) { exitKeywords = keywords }
    func updateWakeKeywords(_ keywords: [String]) { wakeKeywords = keywords }
    func updateResetKeywords(_ keywords: [String]) { resetKeywords = keywords }

    func start() {
        guard state == .idle else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            rtLog("Speech auth status: \(status.rawValue)")
            guard status == .authorized else {
                rtLog("Speech recognition not authorized")
                return
            }
            DispatchQueue.main.async {
                self.setupAudioEngine()
                self.startRecognition()
                self.state = .active
                self.utteranceStartFrame = self.ringBuffer.currentFrame
                self.onStateChange?(.active)
                rtLog("Realtime mode ACTIVE")
            }
        }
    }

    func startWakeMode() {
        guard state == .idle else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }
            DispatchQueue.main.async {
                self.setupAudioEngine()
                self.startRecognition()
                self.state = .wakeListen
                self.onStateChange?(.wakeListen)
                rtLog("Realtime mode WAKE-LISTEN")
            }
        }
    }

    func stop() {
        tearDown()
        state = .idle
        onStateChange?(.idle)
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, let channelData = convertedBuffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
                self.ringBuffer.write(samples)
            }

            self.recognitionRequest?.append(buffer)
        }

        engine.prepare()
        try? engine.start()
    }

    private func startRecognition() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer?.defaultTaskHint = .dictation

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            rtLog("SFSpeechRecognizer not available")
            return
        }
        rtLog("SFSpeechRecognizer available, supportsOnDevice: \(recognizer.supportsOnDeviceRecognition)")

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }

        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = triggerKeywords + exitKeywords + wakeKeywords

        sessionStartTime = Date()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                rtLog("Heard: \(text)")
                self.processRecognitionResult(text, segments: result.bestTranscription.segments)
            }

            let isFinal = result?.isFinal ?? false
            let isNoSpeech = error?.localizedDescription.contains("No speech detected") ?? false

            if let error = error, !isNoSpeech {
                rtLog("Recognition error: \(error.localizedDescription)")
            }

            if isFinal || error != nil {
                let delay = isNoSpeech ? 0.1 : 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.restartRecognitionIfNeeded()
                }
            }
        }

        scheduleSessionRestart()
    }

    private func processRecognitionResult(_ text: String, segments: [SFTranscriptionSegment]) {
        let lowerText = text.lowercased()

        if state == .wakeListen {
            for keyword in wakeKeywords {
                if lowerText.contains(keyword.lowercased()) {
                    rtLog("Wake word detected: \(keyword)")
                    state = .active
                    utteranceStartFrame = ringBuffer.currentFrame
                    onStateChange?(.active)
                    restartRecognitionIfNeeded()
                    return
                }
            }
            return
        }

        guard state == .active else { return }

        for keyword in exitKeywords {
            if lowerText.hasSuffix(keyword.lowercased()) || lowerText.contains(keyword) {
                rtLog("Exit keyword detected: \(keyword)")
                stop()
                return
            }
        }

        for keyword in resetKeywords {
            if lowerText.hasSuffix(keyword.lowercased()) || lowerText.contains(keyword) {
                rtLog("Reset keyword detected: \(keyword) - discarding and restarting")
                utteranceStartFrame = ringBuffer.currentFrame
                restartRecognitionIfNeeded()
                return
            }
        }

        for keyword in triggerKeywords {
            if lowerText.hasSuffix(keyword.lowercased()) || lowerText.hasSuffix(keyword) {
                rtLog("Trigger keyword detected: \(keyword) in text: [\(text)]")
                let content = text
                    .replacingOccurrences(of: keyword, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                rtLog("Content after removing keyword: [\(content)] (len=\(content.count))")
                if !content.isEmpty {
                    state = .transcribing
                    onStateChange?(.transcribing)
                    onSubmit?(content)
                    rtLog("Submitted: \(content)")
                    state = .active
                    onStateChange?(.active)
                } else {
                    rtLog("Content empty, not submitting")
                }
                utteranceStartFrame = ringBuffer.currentFrame
                restartRecognitionIfNeeded()
                return
            }
        }
    }

    private func submitUtterance(endFrame: Int) {
        rtLog("submitUtterance: start=\(utteranceStartFrame) end=\(endFrame) diff=\(endFrame - utteranceStartFrame)")
        guard endFrame > utteranceStartFrame else {
            rtLog("submitUtterance: endFrame <= startFrame, skipping")
            utteranceStartFrame = ringBuffer.currentFrame
            return
        }

        state = .transcribing
        onStateChange?(.transcribing)

        let startFrame = utteranceStartFrame
        utteranceStartFrame = ringBuffer.currentFrame

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self,
                  let samples = self.ringBuffer.slice(from: startFrame, to: endFrame) else {
                rtLog("submitUtterance: slice failed or empty")
                DispatchQueue.main.async {
                    self?.state = .active
                    self?.onStateChange?(.active)
                }
                return
            }

            rtLog("submitUtterance: got \(samples.count) samples (\(Double(samples.count)/16000.0)s)")
            let text = self.transcribeWithWhisper(samples: samples)
            rtLog("submitUtterance: whisper result: \(text ?? "nil")")

            DispatchQueue.main.async {
                if let text = text, !text.isEmpty {
                    self.onSubmit?(text)
                }
                self.state = .active
                self.onStateChange?(.active)
                self.restartRecognitionIfNeeded()
            }
        }
    }

    private func transcribeWithWhisper(samples: [Float]) -> String? {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("realtime_\(Date().timeIntervalSince1970).wav")

        let wavFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard let file = try? AVAudioFile(forWriting: tempURL, settings: wavFormat.settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            channelData[i] = samples[i]
        }
        try? file.write(from: buffer)

        let modelPath = NSString("~/.local/share/whisper-cpp/models").expandingTildeInPath
        let modelDir = URL(fileURLWithPath: modelPath)
        let preferredModels = ["ggml-large-v3-turbo.bin", "ggml-large-v3.bin", "ggml-medium.bin", "ggml-base.bin", "ggml-small.bin", "ggml-tiny.bin"]

        var modelFile: URL?
        for name in preferredModels {
            let candidate = modelDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                modelFile = candidate
                break
            }
        }

        guard let model = modelFile else { return nil }

        let whisperPath = "/opt/homebrew/bin/whisper-cli"
        guard FileManager.default.fileExists(atPath: whisperPath) else { return nil }

        let savedLangs = UserDefaults.standard.stringArray(forKey: "selectedLanguages") ?? []
        let langArg = savedLangs.isEmpty ? "auto" : savedLangs[0]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = ["-m", model.path, "-f", tempURL.path, "-l", langArg, "--no-timestamps", "-t", "4"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        try? FileManager.default.removeItem(at: tempURL)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        var output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = output {
            output = text.replacingOccurrences(of: "\\.$|。$", with: "", options: .regularExpression)
        }
        return output
    }

    private func scheduleSessionRestart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 50) { [weak self] in
            self?.restartRecognitionIfNeeded()
        }
    }

    private func restartRecognitionIfNeeded() {
        guard state == .active || state == .wakeListen else { return }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, (self.state == .active || self.state == .wakeListen) else { return }
            self.startRecognition()
        }
    }

    private func tearDown() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }
}
