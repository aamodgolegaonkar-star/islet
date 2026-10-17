import AppKit
import CoreText
import ObjectiveC
import OpenDirectory
import SwiftUI

/// The lock screen's own clock, hosted for real.
///
/// Full-screen artwork on the lock screen has to cover the system clock, so Islet shows the
/// genuine article in its place: LoginUIKit's (private) `LUI2DateViewController` and
/// `LUI2BigTimeViewController`, the views loginwindow itself uses — Liquid Glass digits in
/// the user's chosen typeface, the system date format and 12/24-hour setting — placed where
/// loginwindow places them. Falls back to nothing if the classes ever disappear.
@MainActor
enum SystemClock {
    /// Offsets of the date and time views from the top of the screen, as fractions of the
    /// screen height (measured from loginwindow's own layout constants: 94.5 pt and
    /// 126.42 pt on a 1050 pt screen).
    static let dateTopRatio: CGFloat = 94.5 / 1050
    static let timeTopRatio: CGFloat = 126.42 / 1050

    static var isAvailable: Bool { classes != nil }

    private static let frameworkLoaded =
        dlopen("/System/Library/PrivateFrameworks/LoginUIKit.framework/LoginUIKit", RTLD_LAZY) != nil

    private static let classes: (date: NSViewController.Type, time: NSViewController.Type)? = {
        guard frameworkLoaded,
              let date = NSClassFromString("LUI2DateViewController") as? NSViewController.Type,
              let time = NSClassFromString("LUI2BigTimeViewController") as? NSViewController.Type
        else {
            Log.lock.error("LoginUIKit clock views unavailable")
            return nil
        }
        return (date, userFontSubclass(of: time) ?? time)
    }()

    /// The signed-in user's own clock settings (face, weight, 24-hour) — loginwindow hands
    /// these to its clock views; without them the views fall back to the default face.
    /// Every private call is checked first: a missing method raises an Objective-C exception,
    /// which would crash the app instead of quietly falling back.
    private static let userClockSettings: NSObject? = {
        let shared = NSSelectorFromString("sharedClockSettingsManager")
        let lookup = NSSelectorFromString("clockSettingsForUserWithGUID:")
        guard frameworkLoaded, let guid = currentUserGUID(),
              let managerClass = NSClassFromString("LUIClockSettingsManager") as? NSObject.Type,
              class_getClassMethod(managerClass, shared) != nil,
              let manager = managerClass.perform(shared)?.takeUnretainedValue() as? NSObject,
              manager.responds(to: lookup),
              let settings = manager.perform(lookup, with: guid)?.takeUnretainedValue() as? NSObject
        else { return nil }
        Log.lock.info("Using the user's lock-screen clock settings: \(settings.description, privacy: .public)")
        return settings
    }()

    private static func currentUserGUID() -> String? {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(),
                                            attributes: [kODAttributeTypeGUID]),
              let values = try? record.values(forAttribute: kODAttributeTypeGUID)
        else { return nil }
        return values.first as? String
    }

    /// `LUI2BigTimeViewController` gets its face from `_timeFont`, which looks the user's
    /// font up by name — but CoreText refuses private (dot-prefixed) names to ordinary apps,
    /// so the clock silently falls back to SF Soft. This subclass answers `_timeFont` with
    /// the same face loaded straight from the system font file.
    private static func userFontSubclass(of base: NSViewController.Type) -> NSViewController.Type? {
        let name = "IsletBigTimeViewController"
        if let existing = NSClassFromString(name) as? NSViewController.Type { return existing }
        let timeFont = NSSelectorFromString("_timeFont"), fontSize = NSSelectorFromString("_fontSize")
        guard let settings = userClockSettings,
              let fontName = value(of: settings, "bigClockFontName") as? String,
              let weight = value(of: settings, "bigClockFontWeight") as? Double,
              ClockFont.descriptor(named: fontName) != nil,
              base.instancesRespond(to: timeFont), base.instancesRespond(to: fontSize),
              let sizeIMP = class_getMethodImplementation(base, fontSize),
              let subclass = objc_allocateClassPair(base, name, 0)
        else { return nil }
        typealias SizeFunction = @convention(c) (AnyObject, Selector) -> Double
        let size = unsafeBitCast(sizeIMP, to: SizeFunction.self)
        let font: @convention(block) (AnyObject) -> NSFont? = { controller in
            ClockFont.font(named: fontName, size: CGFloat(size(controller, fontSize)), weight: weight)
        }
        class_addMethod(subclass, timeFont, imp_implementationWithBlock(font), "@@:")
        objc_registerClassPair(subclass)
        Log.lock.info("Clock face: \(fontName, privacy: .public) weight \(weight)")
        return subclass as? NSViewController.Type
    }

    /// Key-value lookup that answers nil, instead of throwing, for a key the class lacks.
    private static func value(of object: NSObject, _ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    static func makeControllers() -> (date: NSViewController, time: NSViewController)? {
        guard let classes else { return nil }
        let date = classes.date.init(), time = classes.time.init()
        // viewDidLoad resets the settings to the defaults, so apply them once the views exist.
        _ = date.view
        _ = time.view
        if let settings = userClockSettings {
            let apply = NSSelectorFromString("setClockSettings:")
            for controller in [date, time] where controller.responds(to: apply) {
                controller.perform(apply, with: settings)
            }
        }
        for name in ["_updateGlassTextViewFont", "_updateTime"] {
            let selector = NSSelectorFromString(name)
            if time.responds(to: selector) { time.perform(selector) }
        }
        return (date, time)
    }

    private static var measuredTimeHeight: CGFloat?

    /// Distance from the top of the screen to the bottom of the clock's digits.
    static func clockBottom(screenHeight: CGFloat) -> CGFloat {
        if measuredTimeHeight == nil, let time = makeControllers()?.time {
            measuredTimeHeight = time.view.fittingSize.height
        }
        return screenHeight * timeTopRatio + (measuredTimeHeight ?? screenHeight * 0.167)
    }
}

/// The lock-screen clock faces (New York, SF Soft, Rail, …) live in ADTNumeric.ttc under
/// private names, so they are loaded by descriptor from the file instead of by name.
/// Called from LoginUIKit's own code paths, hence the lock rather than actor isolation.
enum ClockFont {
    private static let file = URL(fileURLWithPath: "/System/Library/Fonts/ADTNumeric.ttc")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var descriptors: [String: CTFontDescriptor] = [:]
    nonisolated(unsafe) private static var fonts: [String: NSFont] = [:]

    static func descriptor(named name: String) -> CTFontDescriptor? {
        lock.withLock {
            if let cached = descriptors[name] { return cached }
            guard let all = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
                  let match = all.first(where: { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == name })
            else { return nil }
            descriptors[name] = match
            return match
        }
    }

    /// The face at `size`, with its weight axis set to the user's weight (e.g. 300 = thin).
    static func font(named name: String, size: CGFloat, weight: Double) -> NSFont? {
        let key = "\(name)|\(size)|\(weight)"
        if let cached = lock.withLock({ fonts[key] }) { return cached }
        guard let descriptor = descriptor(named: name) else { return nil }
        let weightAxis = 0x7767_6874 // 'wght'
        let varied = weight > 0
            ? CTFontDescriptorCreateCopyWithVariation(descriptor, weightAxis as CFNumber, CGFloat(weight))
            : descriptor
        let font = CTFontCreateWithFontDescriptor(varied, size, nil) as NSFont
        lock.withLock { fonts[key] = font }
        return font
    }
}

/// Hosts the real date and big-time views at loginwindow's positions.
final class SystemClockContainer: NSView {
    private var controllers: [NSViewController] = []
    private var refresh: Timer?

    init?(screenHeight: CGFloat) {
        guard let (date, time) = SystemClock.makeControllers() else { return nil }
        super.init(frame: .zero)
        controllers = [date, time]
        for controller in controllers {
            let view = controller.view
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        }
        date.view.topAnchor.constraint(equalTo: topAnchor, constant: screenHeight * SystemClock.dateTopRatio).isActive = true
        time.view.topAnchor.constraint(equalTo: topAnchor, constant: screenHeight * SystemClock.timeTopRatio).isActive = true
        // The views tick themselves; this is a safety net so the minute never goes stale.
        let update = NSSelectorFromString("_updateTime")
        refresh = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak time] _ in
            MainActor.assumeIsolated {
                if let time, time.responds(to: update) { time.perform(update) }
            }
        }
        refresh?.tolerance = 1
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // Clicks belong to the player underneath, not the clock.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            refresh?.invalidate()
            refresh = nil
        }
    }
}

struct SystemClockView: NSViewRepresentable {
    var screenHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        SystemClockContainer(screenHeight: screenHeight) ?? NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
