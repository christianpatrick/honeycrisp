# HC-042: One source of truth for the brand SVGs

## Why

The website shipped with copies of the brand artwork (the Honeycrisp icon and the five app icons) duplicated from assets/, with a note to sync them by hand. Christian asked the site to use the same SVGs the app and README use, so the copies go away and assets/ becomes the only place artwork lives.

## Scope

- The page imports the icon and the five app icons directly from the repository's assets/ folder, including the favicon, which becomes the imported icon instead of a duplicate in public/.
- The duplicated SVGs under website/src/assets (app-icons, marks, and the unused seed.svg) are deleted.
- The Pages workflow also triggers on assets/**, so artwork changes rebuild and redeploy the site.
- The dev server is allowed to read the repository root, so astro dev keeps working with imports from outside website/.
- AGENTS.md drops the sync-by-hand note and records the shared-source arrangement.

## Out of scope

- christian.jpg, the fonts, og.png, and apple-touch-icon.png, which are website-only assets and stay in website/.
- Any change to the artwork itself or to the app.

## Design

Astro resolves imports outside the project root through Vite, so index.astro uses ../../../assets paths with ?raw for inlining and a plain import for the favicon URL. vite.server.fs.allow in astro.config.mjs covers reading the repository root during astro dev; the build needs nothing extra.

## Test plan

No behavior changes, so no new failing test. The existing eight tests, including the five-apps-in-order assertion against the built page, must stay green and guard the refactor.

## Acceptance criteria

- website/src/assets contains only christian.jpg and the fonts; public/ contains only og.png and apple-touch-icon.png.
- The built page still inlines all five app icons and the masthead icon, and the favicon link resolves to the built copy of assets/marks/honeycrisp-icon.svg.
- npm run build then npm test passes with all eight tests.
- A change under assets/** triggers the Website workflow.
