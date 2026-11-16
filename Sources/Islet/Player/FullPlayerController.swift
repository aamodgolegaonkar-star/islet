import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class FullPlayerModel {
    /// The window is on screen. Content exists only while presented, so a hidden player
    /// costs nothing (no timers, no layers, no images).
    var isPresented = false
    /// Drives every hero frame: false = everything sits at `origin`, true = full layout.
    var isOpen = false
    /// Where the hero starts and ends, in window coordinates (top-left origin).
    var origin: CGRect = .zero
    var originCornerRadius: CGFloat = 12
    var showLyrics = false
    @ObservationIgnored var close: () -> Void = {}
}

final class FullPlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Presents the Apple Music-style full-screen player above everything, with a hero
/// transition from (and back into) the island's artwork.
@MainActor
final class FullPlayerController {
    let model = FullPlayerModel()
    /// Island artwork rectangle in screen coordinates, used as the closing target.
    var closeTarget: () -> CGRect? = { nil }
    var onVisibilityChange: (Bool) -> Void = { _ in }
    private(set) var isVisible = false

    private let store: PlayerStore
    private var window: FullPlayerWindow?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(store: PlayerStore) {
        self.store = store
        model.close = { [weak self] in self?.close() }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Never leave a screen-covering window behind when the user switches apps.
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func toggle(from rect: CGRect?) {
        isVisible ? close() : open(from: rect)
    }

    func open(from screenRect: CGRect?) {
        if isVisible {
            // Reopened while still closing: spring straight back open.
            guard !model.isOpen, model.isPresented else { return }
            installKeyMonitor()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            withAnimation(IslandMotion.panel) { model.isOpen = true }
            return
        }
        let origin = screenRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
        guard let screen = origin ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(screen.frame, display: false)

        model.origin = screenRect.map { local($0, in: screen) } ?? centeredOrigin(in: screen)
        model.originCornerRadius = screenRect == nil ? 24 : 12
        model.isOpen = false
        model.isPresented = true
        isVisible = true
        onVisibilityChange(true)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        installKeyMonitor()
        Task { @MainActor in
            // Let the collapsed frame render once, then spring open.
            try? await Task.sleep(for: .milliseconds(24))
            guard self.isVisible, self.model.isPresented else { return }
            withAnimation(IslandMotion.panel) { self.model.isOpen = true }
        }
    }

    func close() {
        guard isVisible, let window else { return }
        guard model.isOpen else {
            // Closed before the hero started (e.g. the app lost focus at once): just hide.
            finishClosing()
            return
        }
        if let target = closeTarget(), let screen = window.screen {
            model.origin = local(target, in: screen)
            model.originCornerRadius = 7
        } else if let screen = window.screen {
            model.origin = centeredOrigin(in: screen)
        }
        removeKeyMonitor()
        withAnimation(IslandMotion.panel) {
            model.isOpen = false
        } completion: { [weak self] in
            guard let self, !self.model.isOpen else { return }
            self.finishClosing()
        }
    }

    private func finishClosing() {
        removeKeyMonitor()
        window?.orderOut(nil)
        model.isPresented = false
        isVisible = false
        onVisibilityChange(false)
    }

    // MARK: - Window

    private func makeWindow() -> FullPlayerWindow {
        let window = FullPlayerWindow(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("player")
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let router = ClickRouter()
        let host = FirstMouseHostingView(rootView: FullPlayerView(model: model, store: store)
            .allowsWindowActivationEvents(true)
            .environment(\.clickRouter, router))
        host.clickRouter = router
        host.sizingOptions = []
        window.contentView = host
        return window
    }

    private func local(_ rect: CGRect, in screen: NSScreen) -> CGRect {
        CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    private func centeredOrigin(in screen: NSScreen) -> CGRect {
        let side: CGFloat = 120
        return CGRect(x: screen.frame.width / 2 - side / 2, y: screen.frame.height * 0.4 - side / 2,
                      width: side, height: side)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false } ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return false }
        switch event.keyCode {
        case 53: close()                                                   // esc
        case 49: store.togglePlayPause()                                   // space
        case 123: store.seek(to: store.elapsed(at: Date()) - 10)           // left
        case 124: store.seek(to: store.elapsed(at: Date()) + 10)           // right
        case 37:                                                           // L
            withAnimation(IslandMotion.panel) { model.showLyrics.toggle() }
        default: return false
        }
        return true
    }
}
