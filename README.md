# VoiceInput

macOS 语音输入工具，按快捷键录音，自动转录并粘贴到当前终端（如 opencode）。

## 依赖

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)
- whisper.cpp (`brew install whisper-cpp`)
- Whisper 模型文件

## 安装

### 1. 编译

```bash
cd /Users/I027910/Desktop/ju/projects/AIAgentSmartVoiceInput
swift build
cp .build/debug/VoiceInput VoiceInput.app/Contents/MacOS/VoiceInput
codesign -s - --force --deep --entitlements VoiceInput.entitlements VoiceInput.app

swiftc -o inject-helper inject-helper.swift \
  -framework AppKit -framework CoreGraphics -framework Carbon
```

### 2. 下载 Whisper 模型

```bash
mkdir -p ~/.local/share/whisper-cpp/models
curl -L -o ~/.local/share/whisper-cpp/models/ggml-large-v3-turbo.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
```

国内镜像：
```bash
curl -L -o ~/.local/share/whisper-cpp/models/ggml-large-v3-turbo.bin \
  "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
```

### 3. 授权

在 System Settings → Privacy & Security 中：

- **Microphone**：添加 `VoiceInput.app`
- **Accessibility**：添加 `inject-helper`

### 4. 添加到 Login Items（开机自启）

System Settings → General → Login Items → 添加 `VoiceInput.app`

## 使用

```bash
# 启动（会自动在新 Terminal tab 中启动 inject-helper daemon）
open VoiceInput.app
```

快捷键：**Option+Shift+V**

- 第一次按：开始录音（菜单栏图标变 ⏺）
- 第二次按：停止录音，转录，自动粘贴到当前终端并回车发送

## 架构

```
VoiceInput.app          inject-helper --daemon
┌─────────────┐         ┌──────────────────┐
│ 全局热键     │         │ 轮询 /tmp 文件    │
│ 录音(AVAudio)│         │ 检测到文本后:     │
│ 转录(whisper)│──写入──▶│  激活 Terminal    │
│ 写触发文件   │  /tmp/  │  Cmd+V 粘贴      │
└─────────────┘         │  Enter 发送       │
                        └──────────────────┘
```

VoiceInput.app 负责热键、录音、转录，将结果写入 `/tmp/voiceinput_inject.txt`。
inject-helper daemon 在 Terminal 中运行（拥有 Accessibility 权限），轮询该文件，检测到内容后通过 CGEvent 模拟粘贴和回车。

## 手动启动 daemon

如果 daemon 没有自动启动：

```bash
./inject-helper --daemon
```

## 故障排查

- 查看调试日志：`cat /tmp/voiceinput_debug.log`
- 确认 inject-helper 在运行：`pgrep -f "inject-helper --daemon"`
- 确认 inject-helper 有 Accessibility 权限
- 确认 VoiceInput.app 有 Microphone 权限
