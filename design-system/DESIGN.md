# JXRouter Design System Specification

## 1. Visual Geometry & Structure
- **No Pill-Monoculture**: Card surfaces use functional corner radii (`14pt`). Controls, buttons, and inputs use `8pt` rounding. Pill shapes (`9999pt`) are reserved exclusively for status badges (`RUNNING`, `STANDBY`, `ERROR`).
- **Anti-Skinny Layout**: The main popover adheres to a comfortable minimum width (`440pt`–`520pt`), with consistent internal padding floors (`16pt` padding, `12pt` element spacing).

## 2. Surface Elevations
- **Tier 0 (Base Canvas)**: System background / canvas plane (`NSColor.windowBackgroundColor`).
- **Tier 1 (Surface Card)**: Grounded container cards with subtle luminosity difference (`Color.primary.opacity(0.04)`) and a hairline micro-border (`Color.primary.opacity(0.08)`).
- **Tier 2 (Floating/Interactive Panels)**: Elevated hover and active selection rows with delicate drop shadows.
- **Tier 3 (Modals & Overlays)**: Semi-transparent backdrop blur sheets with distinct border dividers.

## 3. Kinetic Feedback & Motion
- Native spring animation (`Animation.spring(response: 0.25, dampingFraction: 0.82)`).
- All transitions respect `@Environment(\.accessibilityReduceMotion)`. When enabled, animations gracefully fall back to zero-duration opacity changes.

