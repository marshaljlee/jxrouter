# UI-UX Re-Architect & Motion Engine Pipeline Checklist

## Phase 0: Forensic Audit & Capability Discovery
- [x] ITEM-001: Discover tech stack, frameworks, and architecture layout
- [x] ITEM-002: Catalog functional workflows and user journeys
- [x] ITEM-003: Build Bidirectional Capability Reach Matrix (Daemon-to-UI and UI-to-Daemon)
- [x] ITEM-004: Audit design debt, layout constraints, theme coherence, and interactive affordances
- [x] ITEM-005: Capture baseline state and document screen views

## Phase 1: Skill Ingestion & External Capability Discovery
- [x] ITEM-006: Ingest Tier 1 UI/UX design & motion guidelines
- [x] ITEM-007: Curate 20 external design and motion capabilities
- [x] ITEM-008: Verify zero-overlap between Tier 1 and Tier 2 capabilities

## Phase 2: Design System Architecture & Asset Acquisition
- [x] ITEM-009: Author canonical design tokens (`design-system/tokens.json`) with 4-tier elevation
- [x] ITEM-010: Write Design System Specification (`design-system/DESIGN.md`)
- [x] ITEM-011: Build Motion Choreography Specification (`.pipeline/MOTION_CHOREOGRAPHY_SPEC.json`)
- [x] ITEM-012: Acquire / verify local zero-cost UI assets and icons in `.pipeline/ASSET_MANIFEST.json`

## Phase 3: Core UI-UX Re-Architecture
- [x] ITEM-013: Modernize Main Dashboard (`JXRouterView.swift`) with anti-skinny layout, fluid elevation & kinetic feedback
- [x] ITEM-014: Upgrade Settings & Configuration Panels (`SettingsView.swift`) with single-theme coherence and micro-interactions
- [x] ITEM-015: Enhance Interactive Claude Chat (`ClaudeChatView.swift`) with media and status affordances
- [x] ITEM-016: Polish Vault & Multi-Agent Views (`VaultViews.swift`, `VaultWorkspaceView.swift`)

## Phase 4: Motion Choreography Implementation
- [x] ITEM-017: Wire spring physics and fluid transition curves into interactive controls
- [x] ITEM-018: Add reduced-motion accessibility overrides (`@Environment(\.accessibilityReduceMotion)`)

## Phase 5: Verification & Quality Gates (G-01 through G-20)
- [x] ITEM-019: Audit bidirectional capability reach: 0 orphan settings, 0 phantom controls
- [x] ITEM-020: Run build and unit test suite verifying zero functional regression
- [x] ITEM-021: Publish final Redesign & Verification Report

