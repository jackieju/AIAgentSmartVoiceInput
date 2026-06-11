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
        Thread.sleep(forTimeInterval: 0.2)
    }
} else {
    guard CommandLine.arguments.count > 1 else { exit(1) }
    injectNow(CommandLine.arguments[1])
}

func getCurrentTerminalTTY() -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", "tell application \"Terminal\" to return tty of selected tab of front window"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let tty = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let tty = tty, !tty.isEmpty, tty != "missing value" {
        return tty
    }
    return nil
}

func injectNow(_ text: String) {
    let pasteboard = NSPasteboard.general
    let old = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    if let termApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
        termApp.activate()
    }
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
