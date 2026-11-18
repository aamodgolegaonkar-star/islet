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
        /// "Partly Cloudy", for the island's weather page.
        var condition = ""
        /// The town, when the location could be named.
        var place: String?
        /// The next few hours, starting with the coming one.
        var hours: [Hour] = []
    }

    struct Hour: Equatable, Identifiable {
        var time: Date
        var temperature: Int
        var symbol: String
        var id: Date { time }
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
                            + "&hourly=temperature_2m,weather_code,is_day&forecast_hours=7"
                            + "&temperature_unit=\(unit)&timezone=auto&forecast_days=2&timeformat=unixtime"),
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
        var hours: [Hour] = []
        if let hourly = root["hourly"] as? [String: Any],
           let times = hourly["time"] as? [NSNumber], let temps = hourly["temperature_2m"] as? [NSNumber],
           let codes = hourly["weather_code"] as? [NSNumber] {
            let days = hourly["is_day"] as? [NSNumber]
            for index in times.indices where index < temps.count && index < codes.count {
                let time = Date(timeIntervalSince1970: times[index].doubleValue)
                guard time > Date() else { continue }
                hours.append(Hour(time: time, temperature: Int(temps[index].doubleValue.rounded()),
                                  symbol: Self.symbol(code: codes[index].intValue, day: days.map { index < $0.count ? $0[index].boolValue : true } ?? true)))
            }
        }
        report = Report(temperature: Int(temperature.rounded()), high: Int(high.rounded()), low: Int(low.rounded()),
                        symbol: Self.symbol(code: code, day: day), fetched: Date(),
                        condition: Self.condition(code: code), place: await place(of: location), hours: Array(hours.prefix(6)))
        return report
    }

    private func locate() async -> CLLocation? {
        if let location, Date().timeIntervalSince(location.timestamp) < 3600 { return location }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorized else { return await approximateLocation() }
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

    private var placeName: (location: CLLocation, name: String?)?
    private var approximate: (location: CLLocation, city: String?)?

    /// Without Location access: the town the internet address points to (geojs.io, no
    /// account), like Canopy. Asked at most every six hours.
    private func approximateLocation() async -> CLLocation? {
        if let approximate, Date().timeIntervalSince(approximate.location.timestamp) < 6 * 3600 { return approximate.location }
        guard let url = URL(string: "https://get.geojs.io/v1/ip/geo.json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lat = Double(root["latitude"] as? String ?? ""), let lon = Double(root["longitude"] as? String ?? "")
        else { return approximate?.location }
        let found = CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0,
                               horizontalAccuracy: 20_000, verticalAccuracy: -1, timestamp: Date())
        approximate = (found, root["city"] as? String)
        placeName = (found, root["city"] as? String)
        return found
    }

    /// The town's name, looked up once per place.
    private func place(of location: CLLocation) async -> String? {
        if let placeName, placeName.location.distance(from: location) < 3000 { return placeName.name }
        let name = try? await CLGeocoder().reverseGeocodeLocation(location).first?.locality
        placeName = (location, name)
        return name
    }

    /// WMO weather codes in words.
    private static func condition(code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly Clear"
        case 2: "Partly Cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67: "Rain"
        case 80...82: "Showers"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorms"
        default: "Cloudy"
        }
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
