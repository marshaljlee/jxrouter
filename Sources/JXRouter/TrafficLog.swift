import Foundation

/// A single intercepted request logged by the proxy for the Logs tab.
struct TrafficEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let host: String
    let action: RouteAction
    let method: String
    let url: String
    let appProcessName: String?
    let duration: TimeInterval?
    /// Set after the response is served by the proxy router.
    var servedBy: String?
    /// True when the request was served by a fallback provider (not the primary).
    var usedFallback: Bool = false
}

/// What the proxy did with a request — routed to a provider, passed through,
/// or blocked.
enum RouteAction: String, Codable, Sendable {
    case routeAI
    case passthrough
    case passThroughOpenAI
    case block
}

/// Thread-safe append-only log of traffic entries.  The proxy writes on its
/// own queue; the UI reads on the main actor.
@MainActor
final class TrafficLog: ObservableObject {
    @Published var entries: [TrafficEntry] = []

    private let maxEntries = 500

    func append(_ entry: TrafficEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
    }

    func updateServed(id: UUID, provider: String?, usedFallback: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].servedBy = provider
        entries[idx].usedFallback = usedFallback
    }

    func clear() {
        entries.removeAll()
    }
}
