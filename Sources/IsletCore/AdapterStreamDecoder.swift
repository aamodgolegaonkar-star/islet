import Foundation

/// Result of decoding one line of `mediaremote-adapter stream` output.
public enum AdapterEvent: Sendable, Equatable {
    case nothingPlaying
    case update(NowPlayingSnapshot)
}

/// Decodes the JSON-lines output of `mediaremote-adapter stream --micros`.
///
/// Each line is `{"type":"data","diff":Bool,"payload":{...}}`. A non-diff payload
/// replaces the whole state; a diff payload is merged, and `null` values remove keys.
/// Not thread-safe: feed it from a single serial context.
public struct AdapterStreamDecoder {
    private var state: [String: Any] = [:]
    private var artwork: Data?
    private var artworkRevision = 0

    public init() {}

    public mutating func consume(line: Data) -> AdapterEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "data",
            let payload = object["payload"] as? [String: Any]
        else { return nil }

        let isDiff = object["diff"] as? Bool ?? false
        if !isDiff {
            state.removeAll()
            if payload["artworkData"] == nil, artwork != nil {
                artwork = nil
                artworkRevision += 1
            }
        }
        for (key, value) in payload {
            if key == "artworkData" {
                artwork = (value as? String).flatMap { Data(base64Encoded: $0) }
                artworkRevision += 1
            } else if value is NSNull {
                state.removeValue(forKey: key)
            } else {
                state[key] = value
            }
        }
        return currentEvent()
    }

    public mutating func consume(line: String) -> AdapterEvent? {
        consume(line: Data(line.utf8))
    }

    private func currentEvent() -> AdapterEvent {
        guard
            let title = state["title"] as? String, !title.isEmpty,
            let bundle = state["bundleIdentifier"] as? String
        else { return .nothingPlaying }

        let playing = (state["playing"] as? NSNumber)?.boolValue ?? false
        let snapshot = NowPlayingSnapshot(
            title: title,
            artist: state["artist"] as? String ?? "",
            album: state["album"] as? String ?? "",
            duration: seconds(micros: "durationMicros", plain: "duration") ?? 0,
            elapsed: seconds(micros: "elapsedTimeMicros", plain: "elapsedTime") ?? 0,
            timestamp: timestamp(),
            playbackRate: number("playbackRate") ?? (playing ? 1 : 0),
            isPlaying: playing,
            bundleIdentifier: bundle,
            artwork: artwork,
            artworkRevision: artworkRevision,
            uniqueIdentifier: (state["uniqueIdentifier"] as? NSNumber)?.stringValue
                ?? state["uniqueIdentifier"] as? String
        )
        return .update(snapshot)
    }

    private func number(_ key: String) -> Double? {
        (state[key] as? NSNumber)?.doubleValue
    }

    private func seconds(micros: String, plain: String) -> Double? {
        if let value = number(micros) { return value / 1_000_000 }
        return number(plain)
    }

    private func timestamp() -> Date {
        if let micros = number("timestampEpochMicros") {
            return Date(timeIntervalSince1970: micros / 1_000_000)
        }
        if let text = state["timestamp"] as? String,
           let date = ISO8601DateFormatter().date(from: text) {
            return date
        }
        return Date()
    }
}
