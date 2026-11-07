import XCTest
import AppKit

/// Tests for `NotificationObserverToken`, the box that lets a notification
/// handler unregister itself.
///
/// Why this exists: `StatusItemManager` builds the Settings window and the Vault
/// window fresh on every open, and each one registered a
/// `NSWindow.willCloseNotification` observer bound to that window. The token was
/// never stored, so `NotificationCenter` kept the block alive after the window
/// was released — one leaked observer per open/close cycle, for as long as the
/// menu-bar app ran.
///
/// These tests pin the two properties the fix depends on:
///   1. the token can be removed from inside its own handler, and
///   2. removing more than once is harmless (the notification and `deinit`
///      can both reach it).
final class NotificationObserverTokenTests: XCTestCase {

    /// The observer must actually unregister, otherwise the fix is cosmetic.
    func testHandlerRemovesItselfOnFirstDelivery() {
        let center = NotificationCenter()
        var fired = 0

        let box = NotificationObserverToken()
        box.value = center.addObserver(
            forName: .testTokenProbe,
            object: nil,
            queue: nil
        ) { _ in
            fired += 1
            box.remove()
        }

        center.post(name: .testTokenProbe, object: nil)
        XCTAssertEqual(fired, 1, "handler should run once")

        // Second post must NOT reach the handler: that is the whole point.
        center.post(name: .testTokenProbe, object: nil)
        XCTAssertEqual(fired, 1, "observer was not removed — it would leak on every cycle")
    }

    /// `deinit` and the handler can both call `remove()`. Neither may crash,
    /// and the observer must end up unregistered either way.
    func testDoubleRemoveIsSafe() {
        let center = NotificationCenter()
        var fired = 0

        do {
            let box = NotificationObserverToken()
            box.value = center.addObserver(
                forName: .testTokenProbe,
                object: nil,
                queue: nil
            ) { _ in
                fired += 1
                box.remove()
                box.remove() // deliberate second call
            }
            center.post(name: .testTokenProbe, object: nil)
        } // box deinits here, calling remove() a third time

        center.post(name: .testTokenProbe, object: nil)
        XCTAssertEqual(fired, 1, "must be unregistered after handler + deinit both ran")
    }

    /// A box that is dropped without ever firing still has to unregister —
    /// this is the "window closed some other way" path.
    func testDeinitAloneRemovesTheObserver() {
        let center = NotificationCenter()
        var fired = 0

        autoreleasepool {
            let box = NotificationObserverToken()
            box.value = center.addObserver(
                forName: .testTokenProbe,
                object: nil,
                queue: nil
            ) { _ in fired += 1 }
        }

        center.post(name: .testTokenProbe, object: nil)
        XCTAssertEqual(fired, 0, "deinit must unregister the observer")
    }

    /// `remove()` before the token is ever assigned must not trap, and a later
    /// assignment must still be removable. Guards the box's own lifecycle.
    func testRemoveBeforeAssignmentIsSafe() {
        let box = NotificationObserverToken()
        XCTAssertNil(box.value)
        box.remove() // no token yet — must not crash

        let center = NotificationCenter()
        var fired = 0
        box.value = center.addObserver(
            forName: .testTokenProbe,
            object: nil,
            queue: nil
        ) { _ in fired += 1 }

        center.post(name: .testTokenProbe, object: nil)
        XCTAssertEqual(fired, 1, "token assigned after an early remove must still work")

        box.remove()
        center.post(name: .testTokenProbe, object: nil)
        XCTAssertEqual(fired, 1, "late-assigned token must still be removable")
    }
}

private extension Notification.Name {
    static let testTokenProbe = Notification.Name("jxrouter.tests.tokenProbe")
}
