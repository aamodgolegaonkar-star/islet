import AppKit

// `--render-snapshots <dir> [--art <image>] [--lrc <file>]` renders the main surfaces
// to PNG offscreen and exits; used to check layouts without screen-recording access.
let arguments = CommandLine.arguments
// Run by Claude Code / Codex hooks: hand the event to the running Islet and exit.
if arguments.contains("--agent-notify") {
    MainActor.assumeIsolated { AgentNotifier.run(arguments) }
}
if let flag = arguments.firstIndex(of: "--render-snapshots"), flag + 1 < arguments.count {
    let value = { (name: String) -> String? in
        arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    let output = URL(fileURLWithPath: arguments[flag + 1])
    SnapshotRenderer.run(output: output, artPath: value("--art"), lrcPath: value("--lrc"))
    exit(0)
}

if #available(macOS 26.0, *), let flag = arguments.firstIndex(of: "--glass-gallery"), flag + 1 < arguments.count {
    NSApplication.shared.setActivationPolicy(.accessory)
    let art = arguments.firstIndex(of: "--art").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    GlassGallery.run(output: arguments[flag + 1], artPath: art)
    NSApplication.shared.run()
}

if let flag = arguments.firstIndex(of: "--perf-probe") {
    NSApplication.shared.setActivationPolicy(.accessory)
    let surface = flag + 1 < arguments.count ? arguments[flag + 1] : "compact"
    let seconds = flag + 2 < arguments.count ? Double(arguments[flag + 2]) ?? 8 : 8
    PerfProbe.run(surface: surface, seconds: seconds)
    NSApplication.shared.run()
}

if arguments.contains("--slider-selftest") {
    NSApplication.shared.setActivationPolicy(.accessory)
    SliderSelfTest.run()
    NSApplication.shared.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
