import SwiftUI

// MARK: - Vault Isolation View

struct VaultIsolationView: View {
    @State private var vaults: [VaultInfo] = [
        VaultInfo(name: "my-project", path: "~/Vaults/my-project", cliCount: 5, status: .active),
        VaultInfo(name: "experimental", path: "~/Vaults/experimental", cliCount: 2, status: .idle),
    ]
    @State private var showCreate = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vaults")
                        .font(.vaultTitle())
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("Isolated environments — your system stays untouched")
                        .font(.vaultUI(size: 12))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                Spacer()
                Button(action: { showCreate = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("New Vault")
                            .font(.vaultUI(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.vaultAccent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            // Vault cards
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vaults) { vault in
                        VaultCard(vault: vault)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Color.dsBackground)
    }
}

struct VaultInfo: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let cliCount: Int
    let status: Status
    
    enum Status { case active, idle, error }
}

struct VaultCard: View {
    let vault: VaultInfo
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.vaultAccentDim)
                    .frame(width: 40, height: 40)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.vaultAccent)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(vault.name)
                        .font(.vaultUI(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dsTextPrimary)
                    
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
                Text(vault.path)
                    .font(.vaultMono(size: 10))
                    .foregroundStyle(Color.dsTextSecondary)
                Text("\(vault.cliCount) CLI\(vault.cliCount == 1 ? "" : "s") installed")
                    .font(.vaultUI(size: 10))
                    .foregroundStyle(Color.dsTextTertiary)
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 8) {
                VaultActionButton(icon: "camera.metering.spot", label: "Snapshot", color: .dsSky)
                VaultActionButton(icon: "arrow.triangle.2.circlepath", label: "Restore", color: .dsGreen)
                VaultActionButton(icon: "trash", label: "Destroy", color: .dsRed)
            }
        }
        .padding(14)
        .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dsBorder, lineWidth: 1))
        .onHover { isHovering = $0 }
    }
    
    private var statusColor: Color {
        switch vault.status {
        case .active: return .dsGreen
        case .idle: return .dsTextSecondary
        case .error: return .dsRed
        }
    }
}

struct VaultActionButton: View {
    let icon: String
    let label: String
    let color: Color
    @State private var isHovering = false
    
    var body: some View {
        Button(action: {}) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isHovering ? color : Color.dsTextSecondary)
                .frame(width: 28, height: 28)
                .background(isHovering ? color.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(label)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Agent Library View

struct AgentLibraryView: View {
    @State private var agents: [AgentInfo] = [
        AgentInfo(name: "Code Reviewer", icon: "magnifyingglass.circle.fill", color: .dsGreen, model: "claude-opus-4", prompt: "Review code for bugs, security issues, and style violations."),
        AgentInfo(name: "Doc Writer", icon: "doc.text.fill", color: .dsSky, model: "claude-sonnet-4", prompt: "Generate comprehensive documentation for code."),
        AgentInfo(name: "Test Generator", icon: "checkmark.shield.fill", color: .dsPurple, model: "claude-sonnet-4", prompt: "Write unit and integration tests."),
        AgentInfo(name: "Refactorer", icon: "arrow.triangle.branch", color: Color.vaultAccent, model: "claude-opus-4", prompt: "Refactor code for better architecture and maintainability."),
    ]
    @State private var showEditor = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agents")
                        .font(.vaultTitle())
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("Custom AI agents with system prompts and permissions")
                        .font(.vaultUI(size: 12))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                Spacer()
                Button(action: { showEditor = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("New Agent")
                            .font(.vaultUI(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.vaultAccent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(agents) { agent in
                        AgentCard(agent: agent)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Color.dsBackground)
    }
}

struct AgentInfo: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let color: Color
    let model: String
    let prompt: String
}

struct AgentCard: View {
    let agent: AgentInfo
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(agent.color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: agent.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(agent.color)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(.vaultUI(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                Text(agent.prompt)
                    .font(.vaultUI(size: 11))
                    .foregroundStyle(Color.dsTextSecondary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                Text(agent.model)
                    .font(.vaultMono(size: 9))
                    .foregroundStyle(Color.dsTextTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.dsBorder, lineWidth: 1))
                
                Button(action: {}) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.vaultAccent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Run agent")
            }
        }
        .padding(14)
        .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dsBorder, lineWidth: 1))
        .onHover { isHovering = $0 }
    }
}

// MARK: - Timeline View

struct TimelineView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Timeline")
                        .font(.vaultTitle())
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("Session checkpoints and branches")
                        .font(.vaultUI(size: 12))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            VStack(spacing: 0) {
                TimelineNode(label: "Session started", time: "10:30 AM", isCheckpoint: true, color: .dsGreen)
                TimelineLine()
                TimelineNode(label: "Checkpoint: initial state", time: "10:31 AM", isCheckpoint: true, color: Color.vaultAccent)
                TimelineLine()
                TimelineNode(label: "3 messages exchanged", time: "10:35 AM", isCheckpoint: false, color: .dsTextSecondary)
                TimelineLine()
                TimelineNode(label: "Checkpoint: after refactor", time: "10:42 AM", isCheckpoint: true, color: Color.vaultAccent)
                TimelineLine()
                TimelineNode(label: "Checkpoint: tests passing", time: "10:55 AM", isCheckpoint: true, color: .dsGreen)
            }
            .padding(.horizontal, 48)
            .padding(.top, 20)
            
            Spacer()
        }
        .background(Color.dsBackground)
    }
}

struct TimelineNode: View {
    let label: String
    let time: String
    let isCheckpoint: Bool
    let color: Color
    
    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(color)
                .frame(width: isCheckpoint ? 12 : 8, height: isCheckpoint ? 12 : 8)
                .overlay(
                    isCheckpoint
                        ? Circle().stroke(Color.dsBackground, lineWidth: 2)
                        : nil
                )
            
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.vaultUI(size: 12, weight: isCheckpoint ? .medium : .regular))
                    .foregroundStyle(Color.dsTextPrimary)
                Text(time)
                    .font(.vaultMono(size: 10))
                    .foregroundStyle(Color.dsTextTertiary)
            }
            
            if isCheckpoint {
                Spacer()
                Button("Restore") {}
                    .buttonStyle(.plain)
                    .font(.vaultUI(size: 10))
                    .foregroundStyle(Color.vaultAccent)
            }
        }
    }
}

struct TimelineLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.dsBorder)
                .frame(width: 2, height: 20)
                .padding(.leading, 5)
            Spacer()
        }
    }
}

// MARK: - Analytics Dashboard View

struct AnalyticsDashboardView: View {
    @Bindable var manager: ProxyManager
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Analytics")
                        .font(.vaultTitle())
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("Usage, costs, and route metrics")
                        .font(.vaultUI(size: 12))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            // Stats cards
            HStack(spacing: 12) {
                StatCard(title: "Requests", value: "\(manager.proxyServer.stats.aiRouted + manager.proxyServer.stats.passthrough)", icon: "arrow.up.arrow.down", color: .dsAccent)
                StatCard(title: "AI Routed", value: "\(manager.proxyServer.stats.aiRouted)", icon: "brain", color: Color.vaultAccent)
                StatCard(title: "Passthrough", value: "\(manager.proxyServer.stats.passthrough)", icon: "arrow.right", color: .dsTextSecondary)
                StatCard(title: "Blocked", value: "\(manager.proxyServer.stats.blocked)", icon: "exclamationmark.triangle", color: .dsRed)
            }
            .padding(.horizontal, 24)
            
            Spacer()
        }
        .background(Color.dsBackground)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                Text(title)
                    .font(.vaultUI(size: 10))
                    .foregroundStyle(Color.dsTextSecondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.dsTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dsBorder, lineWidth: 1))
    }
}

// MARK: - Routing Panel View

struct RoutingPanelView: View {
    @Bindable var manager: ProxyManager
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Routing")
                        .font(.vaultTitle())
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("JXRouter integration and provider configuration")
                        .font(.vaultUI(size: 12))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            // Provider chain
            VStack(alignment: .leading, spacing: 8) {
                Text("PROVIDER CHAIN")
                    .font(.vaultHeader())
                    .foregroundStyle(Color.dsTextSecondary)
                    .padding(.horizontal, 24)
                
                VStack(spacing: 0) {
                    ProviderRow(name: manager.activeProviderName, type: "Cloud", status: .active, latency: "42ms")
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    ProviderRow(name: "llama.cpp", type: "Local", status: .standby, latency: "—")
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    ProviderRow(name: "Ollama", type: "Local", status: .offline, latency: "—")
                }
                .padding(.horizontal, 24)
                .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dsBorder, lineWidth: 1))
                .padding(.horizontal, 24)
            }
            
            Spacer()
        }
        .background(Color.dsBackground)
    }
}

struct ProviderRow: View {
    let name: String
    let type: String
    let status: ProviderStatus
    let latency: String
    
    enum ProviderStatus { case active, standby, offline }
    
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.vaultUI(size: 12, weight: .medium))
                .foregroundStyle(Color.dsTextPrimary)
            Text(type)
                .font(.vaultMono(size: 9))
                .foregroundStyle(Color.dsTextTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.dsSurfaceRaised, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.dsBorder, lineWidth: 1))
            Spacer()
            Text(latency)
                .font(.vaultMono(size: 10))
                .foregroundStyle(Color.dsTextSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    
    private var statusColor: Color {
        switch status {
        case .active: return .vaultRouteHealthy
        case .standby: return .vaultRouteDegraded
        case .offline: return .vaultRouteDown
        }
    }
}

// MARK: - File Explorer View

struct FileExplorerView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files")
                        .font(.vaultTitle())
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("Browse project files with Git status")
                        .font(.vaultUI(size: 12))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                Spacer()
                
                HStack(spacing: 6) {
                    Button(action: {}) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                    .buttonStyle(.plain)
                    Button(action: {}) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            
            // File tree placeholder
            VStack(spacing: 0) {
                FileRow(name: "Sources", isFolder: true, indent: 0)
                FileRow(name: "JXRouter", isFolder: true, indent: 1)
                FileRow(name: "VaultWorkspaceView.swift", isFolder: false, indent: 2, gitStatus: .modified)
                FileRow(name: "ClaudeChatView.swift", isFolder: false, indent: 2, gitStatus: .added)
                FileRow(name: "DesignTokens.swift", isFolder: false, indent: 2)
                FileRow(name: "Tests", isFolder: true, indent: 1)
                FileRow(name: "Package.swift", isFolder: false, indent: 0)
                FileRow(name: "README.md", isFolder: false, indent: 0)
            }
            .padding(.horizontal, 16)
            .background(Color.vaultTerminalBg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.vaultTerminalBorder, lineWidth: 1))
            .padding(.horizontal, 24)
            
            Spacer()
        }
        .background(Color.dsBackground)
    }
}

struct FileRow: View {
    let name: String
    let isFolder: Bool
    let indent: Int
    var gitStatus: GitStatus? = nil
    
    enum GitStatus { case modified, added, deleted }
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<indent, id: \.self) { _ in
                Color.clear.frame(width: 16)
            }
            Image(systemName: isFolder ? "folder.fill" : "doc.fill")
                .font(.system(size: 10))
                .foregroundStyle(isFolder ? .dsOrange : Color(white: 0.6))
            Text(name)
                .font(.vaultMono(size: 11))
                .foregroundStyle(Color.vaultTerminalFg)
            Spacer()
            if let status = gitStatus {
                Text(gitStatusText(status))
                    .font(.vaultMono(size: 8))
                    .foregroundStyle(gitStatusColor(status))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
    
    private func gitStatusText(_ status: GitStatus) -> String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        }
    }
    
    private func gitStatusColor(_ status: GitStatus) -> Color {
        switch status {
        case .modified: return .dsOrange
        case .added: return .dsGreen
        case .deleted: return .dsRed
        }
    }
}

// MARK: - Vault Settings View

struct VaultSettingsView: View {
    @Bindable var manager: ProxyManager
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.vaultTitle())
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("Vault, routing, and security configuration")
                        .font(.vaultUI(size: 12))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            ScrollView {
                VStack(spacing: 16) {
                    // Vault defaults
                    SettingsSection(title: "Vault Defaults") {
                        SettingsRow(label: "Default Shell", value: "zsh")
                        SettingsRow(label: "Snapshot Rotation", value: "3 generations")
                        SettingsRow(label: "Auto-snapshot on Destroy", value: "On")
                    }
                    
                    // Routing
                    SettingsSection(title: "Routing") {
                        SettingsRow(label: "Proxy Port", value: "5255")
                        SettingsRow(label: "Control Port", value: "5355")
                        SettingsRow(label: "Auto Fallback", value: "On")
                        SettingsRow(label: "Local Provider", value: "llama.cpp (port 8080)")
                    }
                    
                    // Security
                    SettingsSection(title: "Security") {
                        SettingsRow(label: "Key Storage", value: "macOS Keychain")
                        SettingsRow(label: "Isolation Level", value: "Tier-1 (Env)")
                        SettingsRow(label: "Telemetry", value: "Off")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Color.dsBackground)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.vaultHeader())
                .foregroundStyle(Color.dsTextSecondary)
                .padding(.horizontal, 4)
            
            VStack(spacing: 0) {
                content
            }
            .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dsBorder, lineWidth: 1))
        }
    }
}

struct SettingsRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.vaultUI(size: 12))
                .foregroundStyle(Color.dsTextPrimary)
            Spacer()
            Text(value)
                .font(.vaultMono(size: 11))
                .foregroundStyle(Color.dsTextSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        
        // Separator between rows (handled by parent VStack spacing)
    }
}
