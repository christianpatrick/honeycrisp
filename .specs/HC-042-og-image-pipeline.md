# HC-042: The social card rides the asset pipeline

## Why

The social card at website/public/og.png ships to production byte for byte, because Astro copies public/ verbatim and its image pipeline only touches assets imported from src/. The current card is a 3600 by 1890 RGBA png weighing 751 KB, three times the 1200 by 630 size link previews actually render at, and every pixel of alpha is wasted on a card that never shows transparency. The card also changes every time an app joins the letter, so a one-time manual re-export would rot; the optimization belongs in the build, where the full-resolution source stays in the repository and the shipped file is derived from it on every build.

## Scope

- Move og.png from website/public/ to website/src/assets/ so the build owns it.
- Optimize it at build time with getImage from astro:assets: resized to 2400 by 1260, which is two times the standard card size, and re-encoded as jpeg.
- Point og:image at the built, hashed asset as an absolute URL on https://honeycrisp.app.
- Declare og:image:width and og:image:height so scrapers can lay the card out without fetching it first.

## Out of scope

- Generating the card from page content or templates. The source image stays Christian's own artwork, updated by hand.
- webp or avif output. A few link preview scrapers still cannot read them, so the card stays jpeg.
- Any other image on the page. The screenshots and portrait already go through the pipeline, and apple-touch-icon.png stays in public/ because its URL must be stable and unhashed.
- twitter:image and alt text tags. The twitter:card tag already falls back to og:image.

## Design

index.astro imports the card from src/assets and calls getImage with width 2400 and format jpg in the frontmatter, since a meta tag needs a URL rather than an Image component. The absolute URL is built from the returned src and Astro.site, exactly as the canonical URL already is. Sharp runs at its default jpeg quality. The public/ copy is deleted, not duplicated, so dist/ no longer contains og.png and the only shipped card is the hashed jpeg under /_astro/.

## Test plan

A new assertion block in website/test/dist.test.js, running against the built page like the rest of that file:

- og:image points at an absolute https://honeycrisp.app/_astro/ URL ending in .jpg.
- The file that URL names exists in dist/ and is smaller than 400 KB, well under the 751 KB source and with headroom over the roughly 207 KB a 2400 pixel jpeg re-encode measures today.
- og:image:width is 2400 and og:image:height is 1260.
- dist/og.png no longer exists.

## Acceptance criteria

- npm run build then npm test passes inside website/, with the new test failing before the change and passing after.
- The shipped card is a hashed jpeg under dist/_astro/ at 2400 by 1260, under 400 KB.
- The full-resolution png source lives at website/src/assets/og.png and public/ no longer carries a card.
- The og:image URL in the built page is absolute, because scrapers do not resolve relative URLs reliably.
