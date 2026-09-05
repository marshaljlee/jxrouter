import Foundation

// MARK: - Persisted Data Models

struct PersistedVault: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var path: String
    var cliCount: Int
    var isActive: Bool
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, path: String, cliCount: Int = 0, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.cliCount = cliCount
        self.isActive = isActive
        self.createdAt = Date()
    }
}

struct PersistedAgent: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var icon: String
    var colorHex: String
    var model: String
    var systemPrompt: String
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, icon: String, colorHex: String, model: String, systemPrompt: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.model = model
        self.systemPrompt = systemPrompt
        self.createdAt = Date()
    }
}

struct PersistedTimelineEntry: Identifiable, Codable {
    let id: String
    let label: String
    let timestamp: Date
    let isCheckpoint: Bool

    init(label: String, isCheckpoint: Bool = false) {
        self.id = UUID().uuidString
        self.label = label
        self.timestamp = Date()
        self.isCheckpoint = isCheckpoint
    }
}

struct PersistedSession: Identifiable, Codable {
    var id: String
    var name: String
    var createdAt: Date
    var lastMessageAt: Date?
    var messageCount: Int

    init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.lastMessageAt = nil
        self.messageCount = 0
    }
}

// MARK: - Data Store

/// Central persistence store for vault, agent, timeline, and session data.
/// Data lives in ~/Library/Application Support/JXRouter/ as JSON files.
final class DataStore {
    static let shared = DataStore()

    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Root directory for all persisted data.
    private var dataDir: URL {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("JXRouter", isDirectory: true)
    }

    private func ensureDir() throws {
        if !fm.fileExists(atPath: dataDir.path) {
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Vaults

    private var vaultsFile: URL { dataDir.appendingPathComponent("vaults.json") }

    func loadVaults() -> [PersistedVault] {
        guard let data = try? Data(contentsOf: vaultsFile) else { return defaultVaults() }
        return (try? decoder.decode([PersistedVault].self, from: data)) ?? defaultVaults()
    }

    func saveVaults(_ vaults: [PersistedVault]) {
        try? ensureDir()
        guard let data = try? encoder.encode(vaults) else { return }
        try? data.write(to: vaultsFile, options: .atomic)
    }

    private func defaultVaults() -> [PersistedVault] {
        let defaults = [
            PersistedVault(name: "my-project", path: "~/Vaults/my-project", cliCount: 5, isActive: true),
            PersistedVault(name: "experimental", path: "~/Vaults/experimental", cliCount: 2, isActive: false),
        ]
        saveVaults(defaults)
        return defaults
    }

    // MARK: - Agents

    private var agentsFile: URL { dataDir.appendingPathComponent("agents.json") }

    func loadAgents() -> [PersistedAgent] {
        guard let data = try? Data(contentsOf: agentsFile) else { return defaultAgents() }
        return (try? decoder.decode([PersistedAgent].self, from: data)) ?? defaultAgents()
    }

    func saveAgents(_ agents: [PersistedAgent]) {
        try? ensureDir()
        guard let data = try? encoder.encode(agents) else { return }
        try? data.write(to: agentsFile, options: .atomic)
    }

    private func defaultAgents() -> [PersistedAgent] {
        let defaults = [
            PersistedAgent(name: "Code Reviewer", icon: "magnifyingglass.circle.fill", colorHex: "#34C759", model: "claude-opus-4", systemPrompt: "Review code for bugs, security issues, and style violations."),
            PersistedAgent(name: "Doc Writer", icon: "doc.text.fill", colorHex: "#0A84FF", model: "claude-sonnet-4", systemPrompt: "Generate comprehensive documentation for code."),
            PersistedAgent(name: "Test Generator", icon: "checkmark.shield.fill", colorHex: "#BF5AF2", model: "claude-sonnet-4", systemPrompt: "Write unit and integration tests."),
            PersistedAgent(name: "Refactorer", icon: "arrow.triangle.branch", colorHex: "#FF9F0A", model: "claude-opus-4", systemPrompt: "Refactor code for better architecture and maintainability."),
        ]
        saveAgents(defaults)
        return defaults
    }

    // MARK: - Timeline

    private var timelineFile: URL { dataDir.appendingPathComponent("timeline.json") }

    func loadTimeline() -> [PersistedTimelineEntry] {
        guard let data = try? Data(contentsOf: timelineFile) else { return [] }
        return (try? decoder.decode([PersistedTimelineEntry].self, from: data)) ?? []
    }

    func saveTimeline(_ entries: [PersistedTimelineEntry]) {
        try? ensureDir()
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: timelineFile, options: .atomic)
    }

    func addTimelineEntry(label: String, isCheckpoint: Bool = false) {
        var entries = loadTimeline()
        entries.append(PersistedTimelineEntry(label: label, isCheckpoint: isCheckpoint))
        saveTimeline(entries)
    }

    // MARK: - Sessions

    private var sessionsFile: URL { dataDir.appendingPathComponent("sessions.json") }

    func loadSessions() -> [PersistedSession] {
        guard let data = try? Data(contentsOf: sessionsFile) else { return [] }
        return (try? decoder.decode([PersistedSession].self, from: data)) ?? []
    }

    func saveSessions(_ sessions: [PersistedSession]) {
        try? ensureDir()
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: sessionsFile, options: .atomic)
    }

    func createSession(name: String) -> PersistedSession {
        var sessions = loadSessions()
        let session = PersistedSession(name: name)
        sessions.insert(session, at: 0)
        saveSessions(sessions)
        return session
    }

    func updateSession(id: String, messageCount: Int) {
        var sessions = loadSessions()
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].messageCount = messageCount
            sessions[idx].lastMessageAt = Date()
            saveSessions(sessions)
        }
    }

    func deleteSession(id: String) {
        var sessions = loadSessions()
        sessions.removeAll { $0.id == id }
        saveSessions(sessions)
    }
}
