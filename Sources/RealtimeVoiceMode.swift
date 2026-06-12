import AVFoundation
import Speech
import Foundation

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
    private var onSubmit: ((String) -> Void)?
    private var onStateChange: ((RealtimeVoiceState) -> Void)?

    init(triggerKeywords: [String] = ["发送", "回车", "enter"],
         exitKeywords: [String] = ["退出", "exit"],
         wakeKeywords: [String] = ["hey voice", "嘿语音"],
         onSubmit: ((String) -> Void)? = nil,
         onStateChange: ((RealtimeVoiceState) -> Void)? = nil) {
        self.triggerKeywords = triggerKeywords
        self.exitKeywords = exitKeywords
        self.wakeKeywords = wakeKeywords
        self.onSubmit = onSubmit
        self.onStateChange = onStateChange
        self.ringBuffer = AudioRingBuffer(seconds: 30, sampleRate: 16000)
    }

    func updateTriggerKeywords(_ keywords: [String]) {
        triggerKeywords = keywords
    }

    func start() {
        guard state == .idle else { return }
        setupAudioEngine()
        startRecognition()
        state = .active
        utteranceStartFrame = ringBuffer.currentFrame
        onStateChange?(.active)
    }

    func startWakeMode() {
        guard state == .idle else { return }
        setupAudioEngine()
        startRecognition()
        state = .wakeListen
        onStateChange?(.wakeListen)
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
        let locale = Locale(identifier: "zh-CN")
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        speechRecognizer?.defaultTaskHint = .dictation

        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }

        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = triggerKeywords + exitKeywords + wakeKeywords

        sessionStartTime = Date()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString.lowercased()
                self.processRecognitionResult(text, segments: result.bestTranscription.segments)
            }

            if error != nil || (result?.isFinal ?? false) {
                self.restartRecognitionIfNeeded()
            }
        }

        scheduleSessionRestart()
    }

    private func processRecognitionResult(_ text: String, segments: [SFTranscriptionSegment]) {
        if state == .wakeListen {
            for keyword in wakeKeywords {
                if text.contains(keyword.lowercased()) {
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
            if text.hasSuffix(keyword.lowercased()) || text.hasSuffix(keyword) {
                stop()
                return
            }
        }

        for keyword in triggerKeywords {
            let lowKeyword = keyword.lowercased()
            if text.hasSuffix(lowKeyword) || text.hasSuffix(keyword) {
                let triggerFrame = ringBuffer.currentFrame - Int(16000 * 0.3)
                submitUtterance(endFrame: triggerFrame)
                return
            }
        }
    }

    private func submitUtterance(endFrame: Int) {
        guard endFrame > utteranceStartFrame else {
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
                DispatchQueue.main.async {
                    self?.state = .active
                    self?.onStateChange?(.active)
                }
                return
            }

            let text = self.transcribeWithWhisper(samples: samples)

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
