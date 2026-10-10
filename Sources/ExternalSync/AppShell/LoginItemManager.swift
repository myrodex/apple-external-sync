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
    private let service: SMAppService

    /// When `helperBundleIdentifier` is provided, the manager controls the bundled
    /// helper in `Contents/Library/LoginItems`. With no identifier it controls the
    /// main app login item, which is the correct fallback for a menu-bar/background
    /// app that has no helper target yet.
    public init(helperBundleIdentifier: String? = nil) {
        if let helperBundleIdentifier, !helperBundleIdentifier.isEmpty {
            service = SMAppService.loginItem(identifier: helperBundleIdentifier)
        } else {
            service = .mainApp
        }
    }

    public var isEnabled: Bool {
        service.status == .enabled
    }

    public var requiresApproval: Bool {
        service.status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
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
