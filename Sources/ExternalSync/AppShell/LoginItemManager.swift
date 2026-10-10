import Foundation

public enum LoginItemTarget: String, Codable, Sendable {
    case mainApplication
    case bundledHelper
    case unsupported

    public var title: String {
        switch self {
        case .mainApplication: return "Main app at login"
        case .bundledHelper: return "Bundled background helper"
        case .unsupported: return "Unavailable on this platform"
        }
    }
}

@MainActor
public protocol LoginItemManaging: AnyObject {
    var isEnabled: Bool { get }
    var isSupported: Bool { get }
    var requiresApproval: Bool { get }
    var target: LoginItemTarget { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

public extension LoginItemManaging {
    var requiresApproval: Bool { false }
    var target: LoginItemTarget { .unsupported }
    func openSystemSettings() {}
}

@MainActor
public final class UnsupportedLoginItemManager: LoginItemManaging {
    public let isSupported = false
    public private(set) var isEnabled = false
    public let requiresApproval = false
    public let target: LoginItemTarget = .unsupported

    public init() {}

    public func setEnabled(_ enabled: Bool) throws {
        guard !enabled else { return }
        isEnabled = false
    }

    public func openSystemSettings() {}
}

#if os(macOS)
import ServiceManagement

/// Registers this app's bundled login item through the system API. The app target
/// must include the corresponding helper/login-item configuration; this layer does
/// not launch a second copy of the sync engine.
@MainActor
public final class MacOSLoginItemManager: LoginItemManaging {
    public let isSupported = true
    public let target: LoginItemTarget
    private let service: SMAppService

    /// When `helperBundleIdentifier` is provided, the manager controls the bundled
    /// helper in `Contents/Library/LoginItems`. With no identifier it controls the
    /// main app login item, which is the correct fallback for a menu-bar/background
    /// app that has no helper target yet.
    public init(helperBundleIdentifier: String? = nil) {
        if let helperBundleIdentifier, !helperBundleIdentifier.isEmpty {
            service = SMAppService.loginItem(identifier: helperBundleIdentifier)
            target = .bundledHelper
        } else {
            service = .mainApp
            target = .mainApplication
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
        let helperIdentifier = Bundle.main.object(forInfoDictionaryKey: "ExternalSyncLoginItemBundleIdentifier") as? String
        return MacOSLoginItemManager(helperBundleIdentifier: helperIdentifier)
        #else
        return UnsupportedLoginItemManager()
        #endif
    }
}
