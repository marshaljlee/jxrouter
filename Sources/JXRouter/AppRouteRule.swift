import SwiftUI

/// A per-app routing rule — choose which apps route through JXProxy.
struct AppRouteRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var appName: String
    var bundleIdentifier: String?
    var enabled: Bool
    var action: RouteAction
}

/// Row view for a single app routing rule in the Routing tab.
///
/// Uses value-based callbacks (not `@Binding` / `ForEach($appRoutes)`) so
/// deleting a row never invalidates a dangling binding into the array's
/// old storage — the crash that happened when the SwiftUI view graph
/// tried to copy the row during a post-mutation body update.
struct AppRuleRow: View {
    let rule: AppRouteRule
    let onEnabledChange: (Bool) -> Void
    let onActionChange: (RouteAction) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { onEnabledChange($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.appName)
                    .font(.system(size: DesignToken.captionSize, weight: .medium))
                    .foregroundStyle(Color.dsTextPrimary)
                if let bid = rule.bundleIdentifier {
                    Text(bid)
                        .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                        .foregroundStyle(Color.dsTextTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Picker("", selection: Binding(
                get: { rule.action },
                set: { onActionChange($0) }
            )) {
                Text("Route AI").tag(RouteAction.routeAI)
                Text("Pass Through").tag(RouteAction.passthrough)
                Text("Block").tag(RouteAction.block)
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.dsRed)
        }
        .padding(.horizontal, DesignToken.spacing12)
        .padding(.vertical, DesignToken.spacing8)
    }
}
