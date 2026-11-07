import Foundation

/// Holds a notification observer token so the block that receives the
/// notification can remove itself.
///
/// `NotificationCenter.addObserver(forName:object:queue:using:)` returns the
/// token only *after* the closure is built, so the closure cannot capture that
/// token directly. This box is created first, filled in immediately after, and
/// captured by the closure — which gives the handler a way to unregister
/// itself the first time it runs.
///
/// Use it for observers bound to a short-lived object, such as a window that is
/// rebuilt every time the user opens it. Long-lived observers should instead be
/// appended to the owner's token array and removed in that owner's `deinit`.
///
/// Lives in its own file (like `PortOwner.swift`) because the XCTest bundle
/// compiles a subset of the app sources and does not include
/// `StatusItemManager.swift`, which is AppKit window-management code.
final class NotificationObserverToken: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    var value: NSObjectProtocol? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return token
        }
        set {
            lock.lock()
            token = newValue
            lock.unlock()
        }
    }

    /// Unregister the observer. Safe to call more than once and from any
    /// thread: the notification handler runs on the main queue while `deinit`
    /// may run on either, and both paths can reach the same token.
    func remove() {
        lock.lock()
        let pending = token
        token = nil
        lock.unlock()

        if let pending {
            NotificationCenter.default.removeObserver(pending)
        }
    }

    deinit { remove() }
}
