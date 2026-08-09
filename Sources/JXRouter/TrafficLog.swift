import Foundation
import Observation

struct TrafficEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let host: String
    let action: RouteAction
    let method: String
    let url: String
    let appProcessName: String?
    let duration: TimeInterval?
    /// The upstream provider that actually served this request (routeAI only).
    var servedBy: String?
    /// True when the primary provider failed and a configured fallback served.
    var usedFallback: Bool = false
}

@MainActor
@Observable
final class TrafficLog {
    private(set) var entries: [TrafficEntry] = []
    private let maxEntries = 80

    func append(_ entry: TrafficEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Record which upstream provider served a routed request, and whether a
    /// fallback was used (the primary provider had already failed).
    func updateServed(id: UUID, provider: String?, usedFallback: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].servedBy = provider
        entries[idx].usedFallback = usedFallback
    }
}
