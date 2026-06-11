# HC-014: Chrome consistency and in-app copy trim

- Task number: HC-014 (no GitHub issue yet)
- Status: done
- Date: 2026-06-09

## Why

Christian's first pass through the running app surfaced two paper cuts. First, privacy reassurance copy ("Everything runs on your Mac...") repeats inside the app in three places; the marketing site owns that story, and the app should not editorialize, ever. Second, the chrome is inconsistent: the native segmented pickers follow the system accent (blue on this Mac), the granting controls are brand red, and the Settings toggles sit on the default accent, so three different schemes show at once. The product System direction wants neutral segmented controls (white selected segment on a gray track, like the mock's tabs) with the brand red reserved for interactive accents: buttons, switches, and the granting tri-toggle.

## Scope

- Remove every privacy statement from app surfaces: the Status tab's lock footnote, the onboarding Welcome capsule, and the Settings footer sentence. System permission dialogs keep their usage descriptions (those explain a grant, and Apple requires them).
- ThemedSegments: one custom segmented control matching the mock (gray track, white selected segment, no accent), used for the panel tabs, the Simple and Advanced mode switch, and the onboarding client picker.
- One chrome entry point: a honeycrispChrome() modifier in Theme.swift applying the brand tint at each scene root (panel, onboarding, settings), with the scattered per-control tints removed so the accent is managed in exactly one place. Toggles, prominent buttons, steppers, and links all inherit red; semantic colors (running green, gold read badges, outcome badges) stay semantic.
- Version 0.1.2, repackage, relaunch.

## Out of scope

- Any behavior. No model, gateway, or service changes.

## Test plan

Pure view styling, TDD-exempt per AGENTS.md process rule 2. Verification is the full suite staying green, the rebuilt app relaunching, and eyes on the panel, onboarding, and settings: no blue anywhere, segments neutral, controls red, no privacy copy.

## Acceptance criteria

- No privacy statements remain in any app surface.
- Every segmented control renders the neutral mock style; every accent-driven control renders brand red; the accent is set in one place.
- swift test stays green; v0.1.2 is packaged, running, and tagged.
