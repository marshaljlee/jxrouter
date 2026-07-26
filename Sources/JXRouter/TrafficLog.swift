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
}
