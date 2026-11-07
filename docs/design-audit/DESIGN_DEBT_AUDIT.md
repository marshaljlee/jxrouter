# Design Debt Audit: JXRouter

## 1. Stack Identification
- **Platform**: macOS 14.0+ Universal (Apple Silicon & Intel x86_64)
- **Frameworks**: Native SwiftUI + AppKit (`NSStatusBar`, `NSWindow`, `NSAnimationContext`)
- **Language**: Swift 5.9+ / Swift 6 preview compatibility
- **Runtime Engines**:
  - Embedded in-process `llama.cpp` (`libjxllama.dylib` with arm64 PQ2_0/PTQ1_0 support)
  - Managed local `llama-server` (both stock and bundled PrismML fork)
  - Local HTTP/HTTPS proxy daemon (`ProxyServer.swift`, `WebControlServer.swift`)
- **UI Architecture**:
  - Menu Bar status item (`StatusItemManager.swift`)
  - Main floating popover dashboard (`JXRouterView.swift`)
  - Dedicated preferences window (`SettingsView.swift`)
  - Interactive Claude Chat client view (`ClaudeChatView.swift`)
  - Agent Vault / Workspace multi-agent view (`VaultViews.swift`, `VaultWorkspaceView.swift`)

## 2. Design Debt Analysis
1. **Layout Constraints**:
   - Fixed-size popovers previously caused crowded controls when multiple local models or proxy logs were shown.
   - Settings window needs clear section anchors, unified card paddings (`p-6` desktop standard), and fluid grid arrangement.
2. **Theme & Surface Hierarchy**:
   - Needs strict 4-tier surface elevation tokens:
     - Tier 0: Base Window Background (`NSColor.windowBackgroundColor` / system zinc-950 dark)
     - Tier 1: Surface Card (`surfaceColor` with subtle luminosity contrast and 1px border)
     - Tier 2: Floating/Hover Panels (`bg-surface-elevated` with soft multi-stop shadow)
     - Tier 3: Modals, Dialogs & Flyouts (`backdrop-blur-md` with refined border divider)
3. **Typography & Controls**:
   - Pill radius monoculture replaced with functional geometry:
     - `rounded-2xl` for cards
     - `rounded-lg` for inputs and action buttons
     - Pill shape reserved strictly for status chips (e.g. `ONLINE`, `STANDBY`)
4. **Motion & Interaction Hygiene**:
   - Smooth 150-250ms interactive transitions with spring damping.
   - Strict adherence to `@Environment(\.accessibilityReduceMotion)`.

