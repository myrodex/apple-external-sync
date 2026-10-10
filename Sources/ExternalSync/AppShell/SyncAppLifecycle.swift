import Foundation

/// Optional lifecycle hooks implemented by production coordinators. SwiftUI previews
/// and non-Apple hosts do not need to know about UIKit/AppKit or background schedulers.
@MainActor
public protocol SyncAppLifecycleHandling: AnyObject {
    func applicationWillEnterForeground() async
    func applicationDidEnterBackground()
    func runBackgroundSync() async -> Bool
}
