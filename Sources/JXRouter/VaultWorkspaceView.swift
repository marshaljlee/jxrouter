import SwiftUI

// MARK: - Navigation

enum VaultSidebarItem: String, CaseIterable, Identifiable {
    case chat = "Claude Chat"
    case vaults = "Vaults"
    case agents = "Agents"
    case timeline = "Timeline"
    case analytics = "Analytics"
    case routing = "Routing"
    case files = "Files"
    case settings = "Settings"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .vaults: return "lock.shield.fill"
        case .agents: return "person.2.fill"
        case .timeline: return "clock.arrow.circlepath"
        case .analytics: return "chart.bar.fill"
        case .routing: return "arrow.triangle.branch"
        case .files: return "folder.fill"
        case .settings: return "gearshape.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .chat: return .dsAccent
        case .vaults: return Color.vaultAccent
        case .agents: return .dsPurple
        case .timeline: return .dsSky
        case .analytics: return .dsGreen
        case .routing: return Color.vaultAccent
        case .files: return .dsOrange
        case .settings: return .dsTextSecondary
        }
    }
}

// MARK: - Vault Workspace

struct VaultWorkspaceView: View {
    @Bindable var manager: ProxyManager
    @State private var selectedItem: VaultSidebarItem = .chat
    private var appearanceMode: AppearanceMode {
        AppearanceController.shared.mode
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // MARK: Sidebar
            VaultSidebar(
                selectedItem: $selectedItem,
                manager: manager
            )
            
            Divider()
                .overlay(Color.dsBorder)
            
            // MARK: Content Area
            VaultContentView(
                selectedItem: selectedItem,
                manager: manager
            )
        }
        .background(Color.dsBackground)
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Sidebar

struct VaultSidebar: View {
    @Binding var selectedItem: VaultSidebarItem
    @Bindable var manager: ProxyManager
    @State private var vaultCount = 0
    @State private var agentCount = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // App Logo
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.vaultUI(size: 18, weight: .bold))
                    .foregroundStyle(Color.vaultAccent)
                Text("Vault")
                    .font(.vaultTitle())
                    .foregroundStyle(Color.dsTextPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
            
            // Navigation Items
            VStack(spacing: 2) {
                ForEach(VaultSidebarItem.allCases) { item in
                    SidebarRow(
                        item: item,
                        isSelected: selectedItem == item,
                        badge: badgeFor(item)
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedItem = item
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            
            Spacer()
            
            // Bottom: Status + Bridge Toggle
            VStack(spacing: 8) {
                Divider().overlay(Color.dsBorder)
                
                // Proxy status
                HStack(spacing: 6) {
                    Circle()
                        .fill(manager.isRunning ? Color.dsGreen : Color.dsTextSecondary)
                        .frame(width: 6, height: 6)
                    Text(manager.isRunning ? "Router Active" : "Router Off")
                        .font(.vaultUI(size: 11))
                        .foregroundStyle(Color.dsTextSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                
                // Bridge mode toggle
                BridgeModeToggle()
            }
            .padding(.bottom, 12)
        }
        .frame(width: 200)
        .background(Color.dsSurface)
    }
    
    private func badgeFor(_ item: VaultSidebarItem) -> String? {
        switch item {
        case .vaults: return vaultCount > 0 ? "\(vaultCount)" : nil
        case .agents: return agentCount > 0 ? "\(agentCount)" : nil
        default: return nil
        }
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let item: VaultSidebarItem
    let isSelected: Bool
    let badge: String?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? item.color : Color.dsTextSecondary)
                    .frame(width: 18)
                
                Text(item.rawValue)
                    .font(.vaultUI(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.dsTextPrimary : Color.dsTextSecondary)
                
                Spacer()
                
                if let badge {
                    Text(badge)
                        .font(.vaultUI(size: 10, weight: .bold))
                        .foregroundStyle(Color.dsTextPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.color.opacity(0.2), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? item.color.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: DesignToken.radiusButton)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignToken.radiusButton)
                    .stroke(isSelected ? item.color.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bridge Mode Toggle

struct BridgeModeToggle: View {
    @AppStorage("vaultBridgeMode") private var isBridged = false
    
    var body: some View {
        Button(action: { isBridged.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: isBridged ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isBridged ? Color.vaultBridge : Color.vaultSandbox)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(isBridged ? "BRIDGE" : "SANDBOX")
                        .font(.vaultUI(size: 10, weight: .bold))
                        .foregroundStyle(isBridged ? Color.vaultBridge : Color.vaultSandbox)
                    Text(isBridged ? "System shell" : "Isolated")
                        .font(.vaultUI(size: 9))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                
                Spacer()
                
                RoundedRectangle(cornerRadius: 12)
                    .fill(isBridged ? Color.vaultBridge : Color.vaultSandbox)
                    .frame(width: 32, height: 18)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .offset(x: isBridged ? 7 : -7)
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                (isBridged ? Color.vaultBridgeDim : Color.vaultSandboxDim),
                in: RoundedRectangle(cornerRadius: DesignToken.radiusButton)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignToken.radiusButton)
                    .stroke(
                        (isBridged ? Color.vaultBridge : Color.vaultSandbox).opacity(0.3),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

// MARK: - Content Router

struct VaultContentView: View {
    let selectedItem: VaultSidebarItem
    @Bindable var manager: ProxyManager
    
    var body: some View {
        switch selectedItem {
        case .chat:
            ClaudeChatView(manager: manager)
        case .vaults:
            VaultIsolationView()
        case .agents:
            AgentLibraryView()
        case .timeline:
            TimelineView()
        case .analytics:
            AnalyticsDashboardView(manager: manager)
        case .routing:
            RoutingPanelView(manager: manager)
        case .files:
            FileExplorerView()
        case .settings:
            VaultSettingsView(manager: manager)
        }
    }
}
