import Foundation

@MainActor
public protocol LoginItemManaging: AnyObject {
    var isEnabled: Bool { get }
    var isSupported: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
public final class UnsupportedLoginItemManager: LoginItemManaging {
    public let isSupported = false
    public private(set) var isEnabled = false

    public init() {}

    public func setEnabled(_ enabled: Bool) throws {
        guard !enabled else { return }
        isEnabled = false
    }
}

#if os(macOS)
import ServiceManagement

/// Registers this app's bundled login item through the system API. The app target
/// must include the corresponding helper/login-item configuration; this layer does
/// not launch a second copy of the sync engine.
@MainActor
public final class MacOSLoginItemManager: LoginItemManaging {
    public let isSupported = true

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public init() {}

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
#endif

@MainActor
public enum LoginItemManagerFactory {
    public static func makeDefault() -> any LoginItemManaging {
        #if os(macOS)
        return MacOSLoginItemManager()
        #else
        return UnsupportedLoginItemManager()
        #endif
    }
}
