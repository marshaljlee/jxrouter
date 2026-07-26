import SwiftUI

struct JXRouterView: View {
    @Bindable var manager: ProxyManager
    @Environment(\.openSettings) private var showSettings
    @State private var isSettingsPresented = false
    
    // Derived proxy stats for the dashboard
    private var requestsCount: Int {
        manager.proxyServer.stats.aiRouted + manager.proxyServer.stats.passthrough
    }
    
    private var successRate: Double {
        let total = max(1, requestsCount + manager.proxyServer.stats.blocked)
        let success = requestsCount
        return (Double(success) / Double(total)) * 100.0
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main Dashboard Panel
            VStack(spacing: 0) {
                // Header / Toolbar
                HStack {
                    // Traffic lights area (macOS native buttons are provided by the window, so we just pad this space)
                    Spacer()
                    
                    // Toolbar icons
                    HStack(spacing: 12) {
                        Button(action: { /* Shield action */ }) {
                            Image(systemName: "shield")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.dsTextPrimary)
                        .accessibilityLabel("Security Status")
                        
                        Button(action: openSettings) {
                            Image(systemName: "gearshape.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.dsTextPrimary)
                        .accessibilityLabel("Open Settings")
                    }
                    .padding(.trailing, 16)
                }
                .frame(height: 38)
                .padding(.top, 4)
                
                Spacer().frame(height: 12)
                
                // Hero Status
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.dsBorder, lineWidth: 2)
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(manager.isRunning ? Color.dsGreen : Color.dsTextSecondary)
                }
                
                Text(manager.isRunning ? "Running" : "Stopped")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.dsTextPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            
            Spacer().frame(height: 12)
            
            // Actions
            HStack(spacing: 12) {
                Button(action: { Task { await manager.isRunning ? manager.stopProxy() : manager.startProxy() } }) {
                    HStack {
                        Image(systemName: manager.isRunning ? "stop.fill" : "play.fill")
                        Text(manager.isRunning ? "Stop" : "Start")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(manager.isRunning ? Color.dsRedDim : Color.dsGreenDim)
                    .foregroundColor(manager.isRunning ? Color.dsRed : Color.dsGreen)
                    .clipShape(RoundedRectangle(cornerRadius: DesignToken.radiusButton))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignToken.radiusButton)
                            .stroke(manager.isRunning ? Color.dsRed.opacity(0.3) : Color.dsGreen.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(manager.isRunning ? "Stop Proxy" : "Start Proxy")
                
                Button(action: { Task { await manager.restartProxy() } }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Restart")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.dsOrangeDim)
                    .foregroundColor(Color.dsOrange)
                    .clipShape(RoundedRectangle(cornerRadius: DesignToken.radiusButton))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignToken.radiusButton)
                            .stroke(Color.dsOrange.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Restart Proxy")
                
                Button(action: { /* Uninstall logic */ }) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Uninstall")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.dsSurfaceRaised)
                    .foregroundColor(Color.dsTextSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: DesignToken.radiusButton))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignToken.radiusButton)
                            .stroke(Color.dsBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Uninstall JXProxy")
            }
            .padding(.horizontal, 16)
            
            Spacer().frame(height: 24)
            
            // Stats Grid
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatCard(icon: "arrow.up.arrow.down", title: "REQUESTS", value: "\(requestsCount)")
                StatCard(icon: "checkmark.seal.fill", title: "SUCCESS RATE", value: String(format: "%.1f%%", successRate), iconColor: .dsGreen)
                StatCard(icon: "globe", title: "PROVIDERS", value: "\(manager.providers.count)", iconColor: .dsOrange)
                StatCard(icon: "clock.fill", title: "UPTIME", value: formatUptime(manager.uptime), iconColor: .dsOrange)
            }
            .padding(.horizontal, 16)
            
            Spacer().frame(height: 20)
            
            // Detected Apps
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("DETECTED APPS (\(manager.appDetector.detectedApps.count))")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.dsTextSecondary)
                .padding(.horizontal, 20)
                
                // Footer Banner
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.dsTextSecondary)
                    Text("Listening on port \(manager.currentPort)...")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(Color.dsSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }
            
        }
        .frame(width: 380, height: 600)
        .background(Color.dsBackground)
        
        // Slide-out Settings Panel
        if isSettingsPresented {
            Divider()
                .ignoresSafeArea()
            SettingsView(manager: manager)
                .transition(.move(edge: .trailing))
        }
        }
        .background(Color.dsBackground)
        .alert("Claude Code Missing", isPresented: $manager.showClaudeInstallPrompt) {
            Button("Install Now") {
                manager.installAndLaunchClaude()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Anthropic's Claude Code CLI tool was not found on your system. Would you like JXProxy to install it via npm? (Requires npm to be installed)")
        }
    }
    
    private func openSettings() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isSettingsPresented.toggle()
        }
    }
    
    private func formatUptime(_ interval: TimeInterval) -> String {
        if interval == 0 { return "0s" }
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        let s = Int(interval) % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

private struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    var iconColor: Color = .dsTextSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dsTextSecondary)
            }
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.dsTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.dsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
