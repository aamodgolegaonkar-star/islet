import CoreLocation
import IsletCore
import Foundation
import IOBluetooth

/// Current conditions for the lock screen, from Open-Meteo (free, no account) for the Mac's
/// location. Location is asked for only when the weather widget is turned on.
@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    struct Report: Equatable {
        var temperature: Int
        var high: Int
        var low: Int
        var symbol: String
        var fetched: Date
    }

    private(set) var report: Report?
    private let manager = CLLocationManager()
    private var location: CLLocation?
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Asks for location (from Settings, when the widget is turned on).
    func requestAccess() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// A report no older than 20 minutes, or nil without location or a connection.
    func current() async -> Report? {
        if let report, Date().timeIntervalSince(report.fetched) < 20 * 60 { return report }
        guard let location = await locate() else { return report }
        let lat = location.coordinate.latitude, lon = location.coordinate.longitude
        let unit = Locale.current.measurementSystem == .us ? "fahrenheit" : "celsius"
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
                            + "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min"
                            + "&temperature_unit=\(unit)&timezone=auto&forecast_days=1"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let now = root["current"] as? [String: Any],
              let temperature = (now["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (now["weather_code"] as? NSNumber)?.intValue
        else { return report }
        let daily = root["daily"] as? [String: Any]
        let high = ((daily?["temperature_2m_max"] as? [NSNumber])?.first?.doubleValue) ?? temperature
        let low = ((daily?["temperature_2m_min"] as? [NSNumber])?.first?.doubleValue) ?? temperature
        let day = (now["is_day"] as? NSNumber)?.boolValue ?? true
        report = Report(temperature: Int(temperature.rounded()), high: Int(high.rounded()), low: Int(low.rounded()),
                        symbol: Self.symbol(code: code, day: day), fetched: Date())
        return report
    }

    private func locate() async -> CLLocation? {
        if let location, Date().timeIntervalSince(location.timestamp) < 3600 { return location }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorized else { return location }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        MainActor.assumeIsolated {
            location = latest ?? location
            finish()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated { finish() }
    }

    private func finish() {
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume(returning: location) }
    }

    /// WMO weather codes to SF Symbols.
    private static func symbol(code: Int, day: Bool) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

/// Connected headphones' battery for the lock screen, read from Bluetooth (AirPods and
/// Beats report each bud and the case; others one level).
struct HeadphoneStatus: Equatable {
    var name: String
    var symbol: String
    var battery: HeadphoneBattery

    /// The lowest level, for the ring.
    var level: Int? {
        [battery.left, battery.right, battery.single].compactMap { $0 }.min()
    }

    @MainActor
    static func current() -> HeadphoneStatus? {
        for device in AudioOutputs.pairedHeadphones() where device.isConnected() {
            let percent = { (selector: String) -> Int? in
                typealias Get = @convention(c) (AnyObject, Selector) -> UInt8
                let sel = NSSelectorFromString(selector)
                guard let method = class_getInstanceMethod(type(of: device), sel) else { return nil }
                let value = Int(unsafeBitCast(method_getImplementation(method), to: Get.self)(device, sel))
                return value > 0 && value <= 100 ? value : nil
            }
            let battery = HeadphoneBattery(left: percent("batteryPercentLeft"), right: percent("batteryPercentRight"),
                                           case: percent("batteryPercentCase"),
                                           single: percent("batteryPercentSingle") ?? percent("batteryPercentCombined"))
            guard battery.left != nil || battery.right != nil || battery.single != nil, let name = device.name else { continue }
            let symbol = HeadphoneCatalog.identify(name: name, vendorID: nil, productID: nil)?.symbol ?? "headphones"
            return HeadphoneStatus(name: name, symbol: symbol, battery: battery)
        }
        return nil
    }
}
