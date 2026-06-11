# HC-039: The letter website on GitHub Pages

## Why

Honeycrisp needs a public home that is more welcoming than a README. A design collaboration produced the Honeycrisp design system and a chosen marketing direction, the Letter: a single narrow column that reads as a personal letter from the maker. The delivered design kit has stale copy (four apps instead of five, a "nothing is logged" claim the product does not make, a Homebrew install command that does not exist, and placeholder story text), so the site copy must be rebuilt from README.md, which is the source of truth for product claims and voice. The site must live in this repository without ever touching the Swift app or its release artifacts.

## Scope

- A self-contained Astro project in website/: the letter page, design tokens from the design system, self-hosted OFL webfonts, brand SVGs copied from assets/, and Christian's photo in the polaroid.
- Copy resynced from README.md: five apps including Calendar in README order, privacy phrased as the README phrases it (nothing uploaded, a local activity list you can clear), the real origin story from "Why I built this", and no mention of Homebrew anywhere.
- The one download path is GitHub releases. The page carries a download link to releases/latest that works with no JavaScript, progressively enhanced by a single client-side GitHub API request that labels it with the current version and points it straight at the release zip.
- A footer credit, "Built with apples, not AppleScript, by Christian", linking to https://mynameischristian.com/.
- .github/workflows/website.yml: build and test on pull requests that touch website/**, build and deploy to GitHub Pages on pushes to main that touch website/**. Every action pinned to a commit SHA, matching HC-036.
- Release isolation: semantic-release ignores the website commit scope so site work never cuts an app release. Swift packaging already reads nothing from website/.
- AGENTS.md gains a Website section recording these decisions.

## Out of scope

- A custom domain. The site deploys to https://christianpatrick.github.io/honeycrisp/ until one is chosen; the base path is configuration, not structure.
- Any change to app code, app release outputs, or the README itself.
- More pages. The letter is the site. No blog, no docs section, no analytics of any kind: the product promises no tracking and its website behaves the same way.

## Design

- website/ owns its package.json, package-lock.json, and node_modules; nothing under Sources/, Tests/, or scripts/ knows it exists. The root .gitignore already covers node_modules/ and dist/ at any depth.
- Astro builds static HTML with site https://christianpatrick.github.io and base /honeycrisp. The page is src/pages/index.astro plus global token styles; brand SVGs are inlined at build time so the page makes no icon requests.
- Fonts: Caveat, Newsreader, Sora, and Geist Mono vendored as woff2 under src/assets/fonts with their OFL notice. The design system loads them from Google Fonts, and a privacy-first product site should not phone Google on every visit.
- src/scripts/latest-release.js exports pure functions: pickDownloadAsset(assets) chooses the Honeycrisp-VERSION.zip asset and ignores appcast.xml and the .sha256, and describeRelease(release) turns a release payload into a {version, url} pair or null. Page glue fetches the latest-release endpoint and, on any failure at all, leaves the static releases/latest link untouched.
- The workflow has two jobs. build runs npm ci, npm test, and the Astro build with contents: read only, and uploads the Pages artifact. deploy runs configure-pages (with enablement) and deploy-pages with pages: write and id-token: write, only on main.
- .releaserc.json commit-analyzer gains releaseRules with { "scope": "website", "release": false } ahead of the default rules.

## Test plan

- website/test/latest-release.test.js with node --test, written first and run to fail before src/scripts/latest-release.js exists:
  - pickDownloadAsset returns the Honeycrisp-1.0.1.zip asset from a real v1.0.1 asset list that also holds appcast.xml and Honeycrisp-1.0.1.zip.sha256.
  - pickDownloadAsset returns null for an empty list and for a list with no matching name.
  - describeRelease returns { version: "v1.0.1", url: <zip url> } for the real payload shape, and null when the tag or a usable asset is missing.
- npm run build succeeds and dist/index.html carries the base path, the five app names, the README privacy sentence, no "brew" anywhere, and the mynameischristian.com credit. Checked by a small node --test build assertion run after the build in CI.
- Nothing here is TCC-gated; the Swift test suite is untouched and must stay green.

## Acceptance criteria

- npm test and npm run build pass inside website/.
- dist/index.html contains Mail, Reminders, Calendar, Messages, and Contacts in README order, the sentence fragment "the only record kept is a local activity list you can clear", a link to https://github.com/christianpatrick/honeycrisp/releases/latest, the credit link to https://mynameischristian.com/, and no occurrence of "brew".
- swift build at the repo root is unaffected (no target reads website/).
- A push to main that touches only website/** runs the Pages workflow and produces no app release.
- The one manual step is documented in the PR: GitHub Pages must be set to deploy from GitHub Actions in the repository settings if the workflow's enablement call cannot do it itself.
