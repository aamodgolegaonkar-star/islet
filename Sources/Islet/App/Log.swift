import os

/// Unified logging; read with `log stream --predicate 'subsystem == "local.islet"'`.
enum Log {
    static let media = Logger(subsystem: "local.islet", category: "media")
    static let lyrics = Logger(subsystem: "local.islet", category: "lyrics")
    static let artwork = Logger(subsystem: "local.islet", category: "artwork")
    static let lock = Logger(subsystem: "local.islet", category: "lock")
    static let island = Logger(subsystem: "local.islet", category: "island")
}
