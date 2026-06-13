import CoreGraphics
import Carbon.HIToolbox
import AppKit
import Foundation

let triggerFile = "/tmp/voiceinput_inject.txt"

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--daemon" {
    if !FileManager.default.fileExists(atPath: triggerFile) {
        FileManager.default.createFile(atPath: triggerFile, contents: nil)
    }
    
    print("inject-helper daemon running (polling), watching \(triggerFile)")
    
    while true {
        if let text = try? String(contentsOfFile: triggerFile, encoding: .utf8),
           !text.isEmpty {
            try? "".write(toFile: triggerFile, atomically: false, encoding: .utf8)
            injectNow(text)
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
} else {
    guard CommandLine.arguments.count > 1 else { exit(1) }
    injectNow(CommandLine.arguments[1])
}

func activateTargetTab() {
    let overrideFile = "/tmp/voiceinput_target_override.txt"
    let override = (try? String(contentsOfFile: overrideFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if !override.isEmpty {
        activateByOverride(override)
        return
    }

    let ttyFile = "/tmp/voiceinput_target_tty.txt"
    guard let targetTTY = try? String(contentsOfFile: ttyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          !targetTTY.isEmpty else {
        if let termApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
            termApp.activate()
        }
        return
    }

    let script = """
    tell application "Terminal"
        activate
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "\(targetTTY)" then
                    set selected tab of w to t
                    set index of w to 1
                    return
                end if
            end repeat
        end repeat
    end tell
    """
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
}

func activateByOverride(_ target: String) {
    var script: String

    if target.hasPrefix("tab:") {
        let num = Int(target.replacingOccurrences(of: "tab:", with: "")) ?? 1
        script = """
        tell application "Terminal"
            activate
            set tabCount to 0
            repeat with w in windows
                repeat with t in tabs of w
                    set tabCount to tabCount + 1
                    if tabCount is \(num) then
                        set selected tab of w to t
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    } else if target.hasPrefix("name:") {
        let name = target.replacingOccurrences(of: "name:", with: "")
        script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if name of w contains "\(name)" then
                        set selected tab of w to t
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    } else {
        if let termApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
            termApp.activate()
        }
        return
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
}

func injectNow(_ text: String) {
    let pasteboard = NSPasteboard.general
    let old = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    activateTargetTab()
    Thread.sleep(forTimeInterval: 0.3)

    let source = CGEventSource(stateID: .hidSystemState)
    let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
    let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
    vDown?.flags = .maskCommand
    vUp?.flags = .maskCommand
    vDown?.post(tap: .cghidEventTap)
    vUp?.post(tap: .cghidEventTap)

    Thread.sleep(forTimeInterval: 0.3)

    let enterDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true)
    let enterUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
    enterDown?.post(tap: .cghidEventTap)
    enterUp?.post(tap: .cghidEventTap)

    Thread.sleep(forTimeInterval: 0.2)

    pasteboard.clearContents()
    if let old = old {
        pasteboard.setString(old, forType: .string)
    }
}
