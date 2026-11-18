import Foundation

/// A Focus mode as the user named and styled it in System Settings.
public struct FocusMode: Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var symbol: String
    /// UIKit/AppKit system colour name, e.g. "systemIndigoColor".
    public var tint: String

    public init(identifier: String, name: String, symbol: String, tint: String) {
        self.identifier = identifier
        self.name = name
        self.symbol = symbol
        self.tint = tint
    }
}

/// Reads donotdisturbd's own files in ~/Library/DoNotDisturb/DB. Every way of turning a Focus
/// on (Control Center, iPhone sharing, smart and app triggers) is stored there as an
/// assertion while it lasts, so watching the folder needs no polling and no log stream.
public enum FocusModes {
    /// The mode of the newest live assertion in Assertions.json, nil when no Focus is on.
    public static func activeIdentifier(assertions data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stores = root["data"] as? [[String: Any]] else { return nil }
        let records = stores.flatMap { $0["storeAssertionRecords"] as? [[String: Any]] ?? [] }
        let newest = records.max {
            ($0["assertionStartDateTimestamp"] as? Double ?? 0) < ($1["assertionStartDateTimestamp"] as? Double ?? 0)
        }
        let details = newest?["assertionDetails"] as? [String: Any]
        return details?["assertionDetailsModeIdentifier"] as? String
    }

    /// Every configured mode by identifier, from ModeConfigurations.json.
    public static func modes(configurations data: Data) -> [String: FocusMode] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stores = root["data"] as? [[String: Any]] else { return [:] }
        var result: [String: FocusMode] = [:]
        for store in stores {
            for (key, value) in store["modeConfigurations"] as? [String: Any] ?? [:] {
                guard let mode = (value as? [String: Any])?["mode"] as? [String: Any] else { continue }
                let id = mode["modeIdentifier"] as? String ?? key
                result[id] = FocusMode(identifier: id,
                                       name: mode["name"] as? String ?? "Focus",
                                       symbol: mode["symbolImageName"] as? String ?? "moon.fill",
                                       tint: mode["tintColorName"] as? String ?? "systemIndigoColor")
            }
        }
        return result
    }

    /// The mode for an identifier, falling back to a generic Focus when its configuration
    /// isn't known (a mode shared from another device before it syncs).
    public static func mode(_ identifier: String, in modes: [String: FocusMode]) -> FocusMode {
        modes[identifier] ?? FocusMode(identifier: identifier,
                                       name: identifier == "com.apple.donotdisturb.mode.default" ? "Do Not Disturb" : "Focus",
                                       symbol: "moon.fill", tint: "systemIndigoColor")
    }
}
