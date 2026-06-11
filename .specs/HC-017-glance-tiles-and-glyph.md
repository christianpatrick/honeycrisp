# HC-017: Equal glance tiles and a visible menu bar glyph

## Why

The two Status tiles render at different heights because only "You approved" carries a third line, and the menu bar glyph reads tiny because the brand SVG's star fills only about 64 percent of its 512 canvas, so a 16 point render shows a 10 point star.

## Scope

- Glance tiles: top-aligned, equal heights (the row sizes to the tallest tile and both fill it), rounded-design monospaced digits for the big numbers, and consistent spacing.
- Menu bar glyph: render the template image at 22 points so the visible star lands around 14 points, the typical menu bar glyph presence.
- Version 0.1.5, repackage, relaunch.

## Test plan

View-layer only, TDD-exempt per AGENTS.md process rule 2. Verification: suite green, eyes on the tiles and the menu bar.

## Acceptance criteria

- Both tiles share one height regardless of the sub line; the glyph reads clearly in the menu bar.
- swift test stays green; v0.1.5 packaged, running, tagged.
