import Foundation
import IOKit.ps

struct BatteryState: Equatable {
    var level: Double
    var isCharging: Bool
    var isPluggedIn: Bool
}

/// Internal battery status through the public IOKit power-sources API (nil on desktops).
enum Battery {
    static func current() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            return BatteryState(
                level: min(max(Double(current) / Double(maximum), 0), 1),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}

/// Watches power-source changes and reports the moment a charger is connected.
@MainActor
final class PowerMonitor {
    static let shared = PowerMonitor()

    /// Called with the new state when the Mac goes from battery power to a charger.
    var onPluggedIn: ((BatteryState) -> Void)?
    /// Called once each time the battery drops to 20% and to 10% while unplugged.
    var onLow: ((Int) -> Void)?
    /// Any change in level or power source (Islet Link tells the phone).
    var onStateChange: (() -> Void)?
    private(set) var state = Battery.current()
    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        // C callback without context; it runs on the main run loop we add it to.
        let callback: IOPowerSourceCallbackType = { _ in
            MainActor.assumeIsolated { PowerMonitor.shared.powerChanged() }
        }
        guard let created = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { LiveTuning.shared.refreshBatterySaving() }
        }
        LiveTuning.shared.refreshBatterySaving()
    }

    private var lowPowerObserver: NSObjectProtocol?

    private func powerChanged() {
        let previous = state
        state = Battery.current()
        LiveTuning.shared.refreshBatterySaving()
        if state != previous { onStateChange?() }
        if let state, state.isPluggedIn, previous?.isPluggedIn == false {
            onPluggedIn?(state)
        }
        if let state, !state.isPluggedIn, let before = previous?.level {
            for threshold in [0.2, 0.1] where state.level <= threshold && before > threshold {
                onLow?(Int((state.level * 100).rounded()))
            }
        }
    }
}
