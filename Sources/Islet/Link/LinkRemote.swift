import AppKit
import CoreGraphics

/// The phone driving the Mac: pointer, scrolling, typing, shortcuts and system actions.
/// Pointer and keyboard events need the Accessibility permission Islet already asks for
/// for the media keys; without it they are dropped and the phone is told why.
@MainActor
enum LinkRemote {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static var dragging = false

    // MARK: - Pointer

    static func move(dx: Double, dy: Double) {
        let here = CGEvent(source: nil)?.location ?? .zero
        let target = clamp(CGPoint(x: here.x + dx, y: here.y + dy))
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func click(button: String, count: Int) {
        let at = CGEvent(source: nil)?.location ?? .zero
        let right = button == "right"
        let (down, up): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for click in 1 ... max(1, min(count, 3)) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at,
                                    mouseButton: right ? .right : .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Press-and-hold drags: `down` presses the button, moves drag, `up` lets go.
    static func drag(_ state: String) {
        let at = CGEvent(source: nil)?.location ?? .zero
        let down = state == "down"
        dragging = down
        CGEvent(mouseEventSource: nil, mouseType: down ? .leftMouseDown : .leftMouseUp,
                mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func scroll(dx: Double, dy: Double) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    /// Keeps the pointer on some screen.
    private static func clamp(_ point: CGPoint) -> CGPoint {
        let bounds = NSScreen.screens.reduce(CGRect.null) { union, screen in
            // NSScreen is bottom-left based; CG events are top-left based on the main display.
            let main = NSScreen.screens.first?.frame.height ?? 0
            let frame = screen.frame
            return union.union(CGRect(x: frame.minX, y: main - frame.maxY, width: frame.width, height: frame.height))
        }
        guard !bounds.isNull else { return point }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    // MARK: - Keyboard

    static func type(_ text: String) {
        // Typed as Unicode, so any language and emoji work whatever the Mac's layout.
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            let piece = Array(units[start ..< min(start + 16, units.count)])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// A named key ("return", "left", "a"…) with modifiers ("cmd", "shift", "option", "ctrl").
    static func key(_ name: String, modifiers: [String]) {
        guard let code = keyCodes[name.lowercased()] else { return }
        var flags = CGEventFlags()
        if modifiers.contains("cmd") { flags.insert(.maskCommand) }
        if modifiers.contains("shift") { flags.insert(.maskShift) }
        if modifiers.contains("option") { flags.insert(.maskAlternate) }
        if modifiers.contains("ctrl") { flags.insert(.maskControl) }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// ANSI key codes.
    private static let keyCodes: [String: CGKeyCode] = {
        var codes: [String: CGKeyCode] = [
            "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forwarddelete": 117,
            "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121, "f11": 103, "f12": 111,
        ]
        let letters: [(String, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
            ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29), ("o", 31),
            ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (name, code) in letters { codes[name] = code }
        return codes
    }()

    // MARK: - System

    static func sleepDisplay() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    /// The user's Shortcuts, so the phone can run them.
    static func shortcutNames() async -> [String] {
        let output = await LinkUSB.run("/usr/bin/shortcuts", ["list"])
        guard output.status == 0 else { return [] }
        return output.text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.prefix(60).map { $0 }
    }

    static func runShortcut(_ name: String) {
        Task { _ = await LinkUSB.run("/usr/bin/shortcuts", ["run", name]) }
    }

    /// Find My Mac from the phone: a few loud chimes.
    static func ring() {
        Task { @MainActor in
            for _ in 0 ..< 4 {
                NSSound(named: "Sosumi")?.play()
                Haptics.tap()
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }
}
