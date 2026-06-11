# HC-041: Letter copy corrections

## Why

Christian reviewed the letter and asked for a round of corrections: the "why I built this" section should match the README word for word instead of paraphrasing it, the masthead attribution should go away entirely, the footer credit should simply say "Built with apples by Christian", the headline should read "fully fluent" rather than "finally fluent", the polaroid caption should introduce him by name in a smaller hand, and the personal site link should open in a new tab.

## Scope

- Headline becomes "Your assistant, fully fluent in your Mac." in the page and in the social description.
- The masthead keeps only the icon and wordmark; the handwritten "made with care by Christian" block is removed.
- The story beside the polaroid carries the README's "Why I built this" paragraphs verbatim, all five. The P.P.S. is retired because the Ollama and LM Studio note now lives in the story where the README tells it.
- The footer credit reads "Built with apples by Christian.", still linking to mynameischristian.com, and that link opens in a new tab with rel noopener.
- The polaroid caption reads "Hi, my name's Christian" at a smaller size than the kit's "that's me".
- og.png is re-captured from the rebuilt page so the card shows the new headline and no attribution.

## Out of scope

- Any layout, style, or behavior change. The polaroid, sign-off, and P.S. stay as they are.

## Design

Copy-only edits in website/src/pages/index.astro plus the regenerated og.png.

## Test plan

Copy is docs-tier, so no new failing test is required. The existing eight tests must stay green, and the dist assertions still pin the README privacy sentence, the five apps, the links, and the Plausible setup.

## Acceptance criteria

- The built page contains the new headline, no "made with care" text, the README story word for word including its closing line, and the shortened credit.
- npm run build then npm test passes with all eight tests.
