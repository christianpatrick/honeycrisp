# HC-024: Whole-segment tap targets

- Task number: HC-024 (no GitHub issue yet)
- Status: done
- Date: 2026-06-09

## Why

In the ThemedSegments control (HC-014), only the text of an unselected segment switched it; clicking the padding did nothing. The selected segment carries an opaque fill and is fully tappable, but unselected segments fill with Color.clear, which SwiftUI does not hit-test, so the tappable region collapsed to the glyphs. This hit the panel tabs and the Simple/Advanced switch.

## Scope

- Give each segment's button label .contentShape(Rectangle()) so the entire padded, full-width frame is the hit target regardless of fill.
- Version 0.2.1, repackage, relaunch.

## Test plan

View-layer only, TDD-exempt per AGENTS.md process rule 2. Verification: suite green, and clicking anywhere on Permissions, Activity, Simple, or Advanced switches it.

## Acceptance criteria

- Tapping any part of a segment selects it.
- swift test stays green; v0.2.1 packaged, running, tagged.
