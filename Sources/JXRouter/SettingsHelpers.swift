import SwiftUI

// MARK: - Section Group

struct SectionGroup<Content: View>: View {
    let icon: String
    let title: String
    let content: Content

    init(icon: String, title: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: DesignToken.captionSize, weight: .semibold))
                    .foregroundStyle(Color.dsTextSecondary)
                Text(title.uppercased())
                    .font(.system(size: DesignToken.captionSize, weight: .semibold))
                    .foregroundStyle(Color.dsTextSecondary)
            }
            .padding(.horizontal, DesignToken.spacing16)
            .padding(.top, DesignToken.spacing8)

            VStack(spacing: 0) {
                content
            }
            .background(Color.dsSurface)
            .clipShape(RoundedRectangle(cornerRadius: DesignToken.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: DesignToken.radiusCard)
                    .stroke(Color.dsBorder, lineWidth: 1)
            )
            .padding(.horizontal, DesignToken.spacing16)
        }
    }
}

// MARK: - Labeled Field

struct LabeledField<Content: View>: View {
    let label: String
    let caption: String?
    let content: Content

    init(label: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing4) {
            HStack {
                Text(label)
                    .font(.system(size: DesignToken.captionSize, weight: .medium))
                    .foregroundStyle(Color.dsTextPrimary)
                Spacer()
                content
                    .font(.system(size: DesignToken.captionSize, design: .monospaced))
            }
            if let caption = caption {
                Text(caption)
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)
            }
        }
        .padding(.horizontal, DesignToken.spacing12)
        .padding(.vertical, DesignToken.spacing8)
        .background(Color.dsSurface)
        Divider().background(Color.dsBorder)
    }
}

// MARK: - App Rule Row

struct AppRuleRow: View {
    @Binding var rule: AppRouteRule
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DesignToken.spacing8) {
            Button {
                rule.enabled.toggle()
            } label: {
                Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(rule.enabled ? Color.dsGreen : Color.dsTextTertiary)
                    .font(.system(size: DesignToken.captionSize))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(rule.enabled ? "Disable" : "Enable") rule for \(rule.appName)")

            VStack(alignment: .leading, spacing: 1) {
                Text(rule.appName)
                    .font(.system(size: DesignToken.captionSize, weight: .medium))
                    .foregroundStyle(Color.dsTextPrimary)
                if let bundleId = rule.bundleIdentifier {
                    Text(bundleId)
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }

            Spacer()

            Picker("", selection: $rule.action) {
                Text("Route AI").tag(RouteAction.routeAI)
                Text("Pass Through").tag(RouteAction.passthrough)
                Text("Block").tag(RouteAction.block)
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .accessibilityLabel("Action for \(rule.appName)")

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Color.dsRed)
                    .font(.system(size: DesignToken.captionSize))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete rule for \(rule.appName)")
        }
        .padding(.horizontal, DesignToken.spacing12)
        .padding(.vertical, DesignToken.spacing8)
    }
}

// MARK: - ComboBox (NSViewRepresentable)

/// Native macOS combo box (NSComboBox) wrapped for SwiftUI.
struct ComboBox: NSViewRepresentable {
    @Binding var text: String
    var options: [String]
    /// Called every time the dropdown opens — used to auto-fetch fresh model
    /// lists so the user never needs a manual refresh button.
    var onOpen: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.dataSource = context.coordinator
        comboBox.delegate = context.coordinator
        comboBox.controlSize = .regular
        return comboBox
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {
        // Never fight the user: while they're actively typing in the field, or
        // while the dropdown list is open, don't restore stringValue or rebuild
        // the item list. Doing so mid-edit / mid-selection was wiping the user's
        // model choice back to the old @State value ("reverts to big-pickle").
        let isEditing = nsView.currentEditor() != nil
        let listOpen = context.coordinator.isListOpen
        if !isEditing, !listOpen, nsView.stringValue != text {
            nsView.stringValue = text
        }
        if !isEditing, !listOpen, nsView.numberOfItems != options.count {
            nsView.removeAllItems()
            nsView.addItems(withObjectValues: options)
        }
    }

    class Coordinator: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
        var parent: ComboBox
        /// True while the dropdown list is open — item rebuilds are deferred so
        /// an async model fetch can't reset the list under the user's cursor.
        var isListOpen = false

        init(_ parent: ComboBox) { self.parent = parent }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            guard index >= 0 && index < parent.options.count else { return nil }
            return parent.options[index]
        }

        func numberOfItems(in comboBox: NSComboBox) -> Int {
            parent.options.count
        }

        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            parent.options.first(where: { $0.lowercased().hasPrefix(string.lowercased()) })
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let comboBox = obj.object as? NSComboBox else { return }
            parent.text = comboBox.stringValue
        }

        /// Commit the field value when the user clicks/tabs away (e.g. directly
        /// onto the Save button) so an in-progress edit is never lost.
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let comboBox = obj.object as? NSComboBox else { return }
            parent.text = comboBox.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            parent.text = comboBox.stringValue
        }

        func comboBoxWillPopUp(_ notification: Notification) {
            isListOpen = true
            parent.onOpen?()
        }

        func comboBoxDidClose(_ notification: Notification) {
            isListOpen = false
        }
    }
}

// MARK: - Setting Row

struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: DesignToken.captionSize, weight: .medium))
                .foregroundStyle(Color.dsTextPrimary)
            Spacer()
            content
        }
        .padding(.horizontal, DesignToken.spacing12)
        .padding(.vertical, DesignToken.spacing8)
        .background(Color.dsSurface)
    }
}
