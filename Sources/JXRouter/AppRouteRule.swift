import Foundation

struct AppRouteRule: Identifiable, Sendable, Codable {
    var id = UUID()
    var appName: String
    var bundleIdentifier: String?
    var enabled: Bool
    var action: RouteAction

    enum CodingKeys: String, CodingKey {
        case appName, bundleIdentifier, enabled, action
    }

    init(appName: String, bundleIdentifier: String? = nil, enabled: Bool = true, action: RouteAction = .routeAI) {
        self.id = UUID()
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.enabled = enabled
        self.action = action
    }
}
