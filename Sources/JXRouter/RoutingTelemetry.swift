import Foundation

/// Live observation of which apps are actually talking to the proxy.
///
/// `AppRouteRule` is configuration ("what should happen"); this is telemetry
/// ("what is happening"). Ported from the 01.backup `RoutingApp` model, which
/// the current build dropped — it only kept a bare array of app names and a
/// count, losing the bundle identifier, process IDs and last-seen time that
/// make the Routing tab actionable.
struct AppRoutingTelemetry: Identifiable, Sendable, Equatable {
    var name: String
    var bundleIdentifier: String?
    var detectedAt: Date
    var lastSeen: Date
    var connectionCount: Int
    var processIds: Set<Int32>
    var bytesSeen: Int64

    /// Bundle ID when known, otherwise the name — stable across renames.
    var id: String { bundleIdentifier ?? name }

    var subtitle: String {
        bundleIdentifier ?? "unidentified process"
    }

    var isActive: Bool {
        Date().timeIntervalSince(lastSeen) < 120
    }

    var lastSeenText: String {
        let delta = Date().timeIntervalSince(lastSeen)
        if delta < 5 { return "now" }
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        return "\(Int(delta / 3600))h ago"
    }

    var processText: String {
        let pids = processIds.sorted()
        guard !pids.isEmpty else { return "" }
        let shown = pids.prefix(3).map(String.init).joined(separator: ", ")
        return pids.count > 3 ? "\(shown) +\(pids.count - 3)" : shown
    }
}

/// Thread-safe recorder for per-app proxy activity.
final class RoutingTelemetry: @unchecked Sendable {

    static let shared = RoutingTelemetry()

    private let lock = NSLock()
    private var apps: [String: AppRoutingTelemetry] = [:]

    private init() {}

    /// Record one observed connection. `bytes` is optional payload size.
    func record(name: String, bundleIdentifier: String?, pid: Int32?, bytes: Int64 = 0) {
        lock.lock()
        defer { lock.unlock() }

        let key = bundleIdentifier ?? name
        let now = Date()
        if var entry = apps[key] {
            entry.lastSeen = now
            entry.connectionCount += 1
            entry.bytesSeen += bytes
            if let pid { entry.processIds.insert(pid) }
            // Refresh the display name in case the app was renamed.
            entry.name = name
            apps[key] = entry
        } else {
            apps[key] = AppRoutingTelemetry(
                name: name,
                bundleIdentifier: bundleIdentifier,
                detectedAt: now,
                lastSeen: now,
                connectionCount: 1,
                processIds: pid.map { [$0] } ?? [],
                bytesSeen: bytes
            )
        }
    }

    /// Most recently seen first.
    func snapshot() -> [AppRoutingTelemetry] {
        lock.lock()
        defer { lock.unlock() }
        return apps.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    func entry(for id: String) -> AppRoutingTelemetry? {
        lock.lock()
        defer { lock.unlock() }
        return apps[id]
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        apps.removeAll()
    }
}
