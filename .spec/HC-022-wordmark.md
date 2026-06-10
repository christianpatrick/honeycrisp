# HC-022: The wordmark in the app

- Task number: HC-022 (no GitHub issue yet)
- Status: done
- Date: 2026-06-09

## Why

The brand spec (Honeycrisp brand spec, kept local per the spec rule) locks the brand mark: "Honeycrisp" set in Sora semibold at -0.03em tracking with a brand-red period, sitting beside the icon. The panel header currently renders a plain SF Pro title; Christian wants the real wordmark.

## Scope

- Vendor the Sora variable font (SIL Open Font License, license file committed alongside) under assets/fonts/, copied into the app bundle by the packaging script.
- BrandFont: registers the bundled font with CoreText at launch and hands out Font.custom("Sora") with a system-font fallback for bare swift run, where the bundle resource is absent.
- A Wordmark view rendering the locked mark (Sora semibold, tight tracking, red period), used in the panel header next to the icon.
- The new delivery is gitignored like the first (the brand spec), and AGENTS.md documents it.

## Test plan

View and font plumbing, TDD-exempt per AGENTS.md process rule 2. Verification: suite green, the packaged app shows the wordmark in the header, and the fallback renders sanely under swift run.

## Acceptance criteria

- The panel header shows the Sora wordmark with the red period in the packaged app.
- assets/fonts ships the font plus OFL.txt; packaging copies both.
- swift test stays green.
