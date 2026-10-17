import AppKit
import CoreBluetooth
import CoreWLAN
import IOKit.pwr_mgt

/// The switches behind the island's Control Center. Wi-Fi uses CoreWLAN. Bluetooth's state
/// comes from CoreBluetooth (which asks for permission once and reports changes live);
/// switching it, and locking, use the same private calls the menu bar does, looked up at
/// run time so a missing symbol just disables that control.
@MainActor
@Observable
final class SystemControls {
    static let shared = SystemControls()

    private(set) var wifiOn = false
    private(set) var bluetoothOn = false
    private(set) var darkMode = false
    private(set) var keepAwake = false
    /// Name of the Wi-Fi network in use, when known.
    private(set) var network: String?

    /// False until Bluetooth access is granted, or when the switch can't be found.
    private(set) var bluetoothAllowed = true
    var bluetoothAvailable: Bool { bluetoothAllowed && setBluetooth != nil }

    @ObservationIgnored private var awakeAssertion = IOPMAssertionID(0)
    @ObservationIgnored private let bluetooth = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    private typealias SetPower = @convention(c) (Int32) -> Void
    @ObservationIgnored private let bluetoothWatcher = BluetoothWatcher()
    @ObservationIgnored private lazy var setBluetooth = dlsym(bluetooth, "IOBluetoothPreferenceSetControllerPowerState")
        .map { unsafeBitCast($0, to: SetPower.self) }
    @ObservationIgnored private var appearanceObserver: NSObjectProtocol?

    private init() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SystemControls.shared.refresh() }
        }
        bluetoothWatcher.changed = { state in
            MainActor.assumeIsolated { SystemControls.shared.bluetoothChanged(state) }
        }
        refresh()
    }

    private func bluetoothChanged(_ state: CBManagerState) {
        Log.island.notice("Bluetooth state \(state.rawValue) (5 = on, 4 = off, 3 = not allowed)")
        switch state {
        case .poweredOn: bluetoothOn = true; bluetoothAllowed = true
        case .poweredOff: bluetoothOn = false; bluetoothAllowed = true
        case .unauthorized, .unsupported: bluetoothAllowed = false
        default: break
        }
    }

    /// Reads every switch's current state (the page refreshes when it opens).
    func refresh() {
        let interface = CWWiFiClient.shared().interface()
        wifiOn = interface?.powerOn() ?? false
        network = wifiOn ? interface?.ssid() : nil
        bluetoothChanged(bluetoothWatcher.state)
        darkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    func toggleWiFi() {
        guard let interface = CWWiFiClient.shared().interface() else { return }
        let next = !wifiOn
        wifiOn = next
        if next { network = nil }
        Task.detached {
            try? interface.setPower(next)
            await SystemControls.shared.settle { $0.wifiOn == next }
        }
    }

    func toggleBluetooth() {
        guard bluetoothAllowed else {
            // Not allowed yet: take the user to the switch that allows it.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let setBluetooth else { return }
        let next = !bluetoothOn
        bluetoothOn = next
        // The radio can take a moment to switch; keep the main thread free meanwhile.
        Task.detached {
            setBluetooth(next ? 1 : 0)
            await SystemControls.shared.settle { $0.bluetoothOn == next }
        }
    }

    /// The switch shows its new state at once; this re-reads the hardware until it agrees
    /// (or gives up after a few seconds and shows what the hardware reports).
    private func settle(until done: @MainActor (SystemControls) -> Bool) async {
        let wanted = (wifiOn, bluetoothOn)
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(400))
            refresh()
            if done(self) { return }
            // Keep showing the requested state while the hardware catches up.
            (wifiOn, bluetoothOn) = wanted
        }
        refresh()
    }

    /// Through System Events, as Apple documents; macOS asks once for permission.
    func toggleDarkMode() {
        darkMode.toggle()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(darkMode)"]
        process.terminationHandler = { _ in
            Task { @MainActor in SystemControls.shared.refresh() }
        }
        try? process.run()
    }

    /// Keeps the display awake (and so the Mac) until turned off or Islet quits.
    func toggleKeepAwake() {
        if keepAwake {
            IOPMAssertionRelease(awakeAssertion)
            keepAwake = false
        } else {
            keepAwake = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Islet: Keep Awake" as CFString, &awakeAssertion) == kIOReturnSuccess
        }
    }

    func lockScreen() {
        guard let login = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let symbol = dlsym(login, "SACLockScreenImmediate") else { return }
        typealias Lock = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: Lock.self)()
    }

    func screenshot() {
        let app = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// CoreBluetooth's view of the Bluetooth radio, delivered on the main queue.
private final class BluetoothWatcher: NSObject, CBCentralManagerDelegate {
    var changed: ((CBManagerState) -> Void)?
    private var manager: CBCentralManager?

    var state: CBManagerState { manager?.state ?? .unknown }

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        changed?(central.state)
    }
}
