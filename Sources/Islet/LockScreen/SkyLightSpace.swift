import AppKit

/// A private SkyLight "space" drawn above the lock screen shield.
///
/// macOS has no public API for lock-screen widgets. Windows moved into a SkyLight space
/// with a high absolute level stay visible while the screen is locked. These are private,
/// reverse-engineered calls: every symbol is resolved at runtime and the feature turns
/// itself off if anything is missing.
@MainActor
final class SkyLightSpace {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int, UnsafeRawPointer?) -> UInt64
    private typealias SetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    /// The one lock-screen space Islet uses, so its lock-screen windows stack by level
    /// (widgets over the lyrics backdrop) instead of by which space happens to be on top.
    static let shared: SkyLightSpace? = SkyLightSpace()

    private let connection: Int32
    private let space: UInt64
    private let addWindows: AddWindowsFn

    init?(absoluteLevel: Int32 = 400) {
        guard
            let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let mainConnection = Self.symbol(handle, "SLSMainConnectionID", as: MainConnectionFn.self),
            let create = Self.symbol(handle, "SLSSpaceCreate", as: SpaceCreateFn.self),
            let setLevel = Self.symbol(handle, "SLSSpaceSetAbsoluteLevel", as: SetAbsoluteLevelFn.self),
            let show = Self.symbol(handle, "SLSShowSpaces", as: ShowSpacesFn.self),
            let add = Self.symbol(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindowsFn.self)
        else { return nil }

        connection = mainConnection()
        space = create(connection, 1, nil)
        guard space != 0 else { return nil }
        _ = setLevel(connection, space, absoluteLevel)
        _ = show(connection, [NSNumber(value: space)] as CFArray)
        addWindows = add
    }

    /// Moves the window into the lock-screen space. Call after the window is on screen.
    func attach(_ window: NSWindow) {
        _ = addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}
