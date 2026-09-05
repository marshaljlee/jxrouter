import SwiftUI
import AppKit

/// A simple async semaphore to limit concurrency.
final class AsyncSemaphore: @unchecked Sendable {
    private var value: Int
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { value = count }

    func wait() async {
        // Scoped locking (withLock) — raw lock()/unlock() is unavailable from
        // async contexts in the Swift 6 language mode.
        let shouldWait = lock.withLock { () -> Bool in
            if value > 0 {
                value -= 1
                return false
            }
            return true
        }
        guard shouldWait else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        // Resume outside the lock — resuming inside it can deadlock when the
        // resumed task runs synchronously and re-enters wait().
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let first = waiters.first {
                waiters.removeFirst()
                return first
            } else {
                value += 1
                return nil
            }
        }
        waiter?.resume()
    }
}

/// A SwiftUI wrapper around an NSComboBox that supports dynamic option lists
/// and a trailing action (e.g. "Refresh").  The text binding stays in sync
/// with the combo box's edit field so the caller can read/write the selected
/// value just like a `TextField`.
struct ComboBox: NSViewRepresentable {
    @Binding var text: String
    let options: [String]
    var onOpenMenu: (() -> Void)?

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.completes = true
        combo.usesDataSource = false
        combo.font = NSFont.systemFont(ofSize: DesignToken.caption2Size)
        combo.delegate = context.coordinator
        combo.target = context.coordinator
        combo.action = #selector(Coordinator.comboChanged(_:))

        // Style to match the rounded-border TextField look.
        combo.focusRingType = .exterior
        combo.backgroundColor = .controlBackgroundColor

        combo.removeAllItems()
        combo.addItems(withObjectValues: options)

        // Set initial value
        if !text.isEmpty {
            combo.stringValue = text
        }

        return combo
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {
        // Update options list when it changes — this is critical so the
        // dropdown shows freshly-fetched models as soon as they arrive.
        let currentOptions = nsView.objectValues.compactMap { $0 as? String }
        if currentOptions != options {
            let previousSelection = nsView.stringValue
            nsView.removeAllItems()
            nsView.addItems(withObjectValues: options)
            // Restore the previous selection so the user's pick isn't lost
            // when the list refreshes.
            if !previousSelection.isEmpty {
                nsView.stringValue = previousSelection
            }
        }
        // Keep the displayed text in sync with the binding (but avoid a loop
        // by only writing when the value actually differs).
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSComboBoxDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }

        func controlTextDidChange(_ obj: Notification) {
            guard let combo = obj.object as? NSComboBox else { return }
            text = combo.stringValue
        }

        @objc func comboChanged(_ sender: NSComboBox) {
            text = sender.stringValue
        }

        // When the combo box finishes selecting an item from the dropdown,
        // propagate it to the binding.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            let idx = combo.indexOfSelectedItem
            if idx >= 0, idx < combo.numberOfItems {
                let value = combo.itemObjectValue(at: idx) as? String ?? ""
                text = value
                combo.stringValue = value
            }
        }

        func comboBoxWillDismiss(_ notification: Notification) {
            // After the user picks an item, fire the trailing action (model
            // auto-fetch) so the list refreshes on next open.
        }
    }
}
