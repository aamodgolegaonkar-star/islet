import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import IsletCore
import OpenDirectory
import Security

/// One enrolled face: a name and the fingerprints taken from several angles.
struct EnrolledFace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var enabled = true
    var embeddings: [[Float]]
    /// Looks picked up from unlocks since (`FaceID.learning`). Optional so faces saved
    /// before learning existed still load.
    var learned: [[Float]]?

    var allEmbeddings: [[Float]] { embeddings + (learned ?? []) }
}

/// Face ID's secrets in the login Keychain: the Mac password it types, and the enrolled
/// faces. Nothing goes to disk or to the defaults. Reads never show a prompt (one at the
/// lock screen would hang there).
enum FaceIDKeychain {
    private static let service = "local.islet.faceid"
    static let passwordAccount = "password"
    static let facesAccount = "faces"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        SecItemDelete(base(account) as CFDictionary)
        var item = base(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Islet Face ID"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// The item is there *and* this build may read it. An item saved by a build with a
    /// different signature still exists, but its ACL turns the read into a prompt, which
    /// fails silently at the lock screen.
    static func exists(account: String) -> Bool {
        load(account: account) != nil
    }

    static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    static func loadFaces() -> [EnrolledFace] {
        load(account: facesAccount).flatMap { try? JSONDecoder().decode([EnrolledFace].self, from: $0) } ?? []
    }

    static func saveFaces(_ faces: [EnrolledFace]) {
        guard let data = try? JSONEncoder().encode(faces) else { return }
        save(data, account: facesAccount)
    }
}

/// Checks a password against this Mac's account, once, when it's saved. (Each wrong
/// guess counts against the account, so it is never retried on its own.)
enum MacPassword {
    static func verify(_ password: String) -> Bool {
        guard !password.isEmpty,
              let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(password)) != nil
    }
}

/// What the lock screen is doing, from the window server.
enum LockScreenState {
    static var sessionLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool ?? false
        return locked && onConsole
    }

    /// loginwindow has a window up (the lock screen and its password field).
    static var lockWindowOnScreen: Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "loginwindow" }
    }

    /// The built-in display is off (it sleeps soon after locking).
    static var displayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    /// Seconds since anyone pressed a key.
    static var secondsSinceKeyPress: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    /// Wakes the display and brings up the password field, as a key press would. One
    /// declaration, refreshed each time: a new ID per call was never released and piled up,
    /// telling macOS someone was using the Mac long after they'd gone.
    static func declareActivity() {
        IOPMAssertionDeclareUserActivity("Islet Face ID" as CFString, kIOPMUserActiveLocal, &activity)
    }
    nonisolated(unsafe) private static var activity: IOPMAssertionID = 0
}

/// Types into whatever has keyboard focus. Needs Accessibility access.
enum KeyTyper {
    /// Types `text`, then Return. Refuses (returns false) the moment the screen isn't
    /// locked, when `requireLocked` is set, so a password never lands in an app.
    @discardableResult
    static func type(_ text: String, pressReturn: Bool, requireLocked: Bool) -> Bool {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState) else { return false }
        for character in text {
            if requireLocked, !LockScreenState.sessionLocked { return false }
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return false }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.post(tap: .cghidEventTap)
            }
            usleep(8_000)
        }
        if pressReturn {
            if requireLocked, !LockScreenState.sessionLocked { return false }
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)
            }
        }
        return true
    }
}
