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

func injectNow(_ text: String) {
    if let termApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
        termApp.activate()
        Thread.sleep(forTimeInterval: 0.3)
    }

    let pasteboard = NSPasteboard.general
    let old = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    let source = CGEventSource(stateID: .hidSystemState)
    let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
    let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
    vDown?.flags = .maskCommand
    vUp?.flags = .maskCommand
    vDown?.post(tap: .cghidEventTap)
    vUp?.post(tap: .cghidEventTap)

    Thread.sleep(forTimeInterval: 1.0)

    let enterDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true)
    let enterUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
    enterDown?.post(tap: .cghidEventTap)
    enterUp?.post(tap: .cghidEventTap)

    Thread.sleep(forTimeInterval: 0.3)

    pasteboard.clearContents()
    if let old = old {
        pasteboard.setString(old, forType: .string)
    }
}
