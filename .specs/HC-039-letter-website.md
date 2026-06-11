# HC-039: The letter website at honeycrisp.app

One spec for the whole website effort in this pull request: the letter site itself, the honeycrisp.app domain, Plausible analytics, Christian's copy corrections, and the shared brand artwork.

## Why

Honeycrisp needs a public home that is more welcoming than a README. A design collaboration produced the Honeycrisp design system and a chosen marketing direction, the Letter: a single narrow column that reads as a personal letter from the maker. The delivered design kit had stale copy (four apps instead of five, a "nothing is logged" claim the product does not make, a Homebrew install command that does not exist, and placeholder story text), so the site copy is rebuilt from README.md, which is the source of truth for product claims and voice. The site must live in this repository without ever touching the Swift app or its release artifacts.

## Scope

- A self-contained Astro project in website/: the letter page, design tokens from the design system, self-hosted OFL webfonts, and Christian's photo in the polaroid with the caption "Hi, my name's Christian".
- Copy from README.md, as reviewed by Christian: the headline "Your assistant, fully fluent in your Mac.", five apps including Calendar in README order, privacy phrased as the README phrases it (nothing uploaded, a local activity list you can clear), and the "Why I built this" paragraphs word for word, smiley included. No masthead attribution, and no mention of Homebrew anywhere.
- The one download path is GitHub releases. The page carries a download link to releases/latest that works with no JavaScript, progressively enhanced by a single client-side GitHub API request that labels it with the current version and points it straight at the release zip.
- The site is served at the root of https://honeycrisp.app, the custom domain configured in the repository's Pages settings. GitHub redirects the github.io address on its own.
- Plausible analytics through @plausible-analytics/tracker: cookieless pageviews, outbound link tracking, and a Download custom event carrying the release URL. The site ID is the public domain, hardcoded because it ships in every page's source by design; no repository secret or variable exists for it, and localhost is never captured.
- One source of truth for artwork: the page imports the icon and the five app icons straight from the repository's assets/ folder, the same files the README and app use, including the favicon. No copies under website/.
- A footer credit, "Built with apples by Christian.", linking to https://mynameischristian.com/ in a new tab with rel noopener.
- .github/workflows/website.yml: build and test on pull requests, build and deploy to GitHub Pages on pushes to main, filtered to website/**, assets/**, and the workflow itself. Every action pinned to a commit SHA, matching HC-036.
- Release isolation: semantic-release ignores the website commit scope so site work never cuts an app release. Swift packaging already reads nothing from website/.
- AGENTS.md gains a Website section recording these decisions.

## Out of scope

- Any change to app code, app release outputs, or the README itself.
- More pages. The letter is the site. No blog and no docs section.
- A Plausible proxy, self-hosted endpoint, or adblock evasion of any kind; goal configuration inside the Plausible dashboard.
- A www subdomain or DNS work.

## Design

- website/ owns its package.json, package-lock.json, and node_modules; nothing under Sources/, Tests/, or scripts/ knows it exists. The root .gitignore already covers node_modules/ and dist/ at any depth.
- Astro builds static HTML with site https://honeycrisp.app and no base path. The page is src/pages/index.astro plus global token styles; brand SVGs are inlined at build time so the page makes no icon requests. vite.server.fs.allow covers the repository root so astro dev can read assets/ outside the project.
- Fonts: Caveat, Newsreader, Sora, and Geist Mono vendored as woff2 under src/assets/fonts with their OFL notice. The design system loads them from Google Fonts, and a privacy-first product site should not phone Google on every visit.
- src/scripts/latest-release.js exports pure functions: pickDownloadAsset(assets) chooses the Honeycrisp-VERSION.zip asset and ignores appcast.xml and the .sha256, and describeRelease(release) turns a release payload into a {version, url} pair or null. Page glue fetches the latest-release endpoint and, on any failure at all, leaves the static releases/latest link untouched.
- Analytics is a second small page script: init({ domain: "honeycrisp.app", outboundLinks: true }), plus a click listener on the download link that calls track("Download", { props: { url } }).
- The workflow has two jobs. build runs npm ci, the Astro build, and npm test with contents: read only, and uploads the Pages artifact. deploy runs configure-pages (with enablement) and deploy-pages with pages: write and id-token: write, only on main.
- .releaserc.json commit-analyzer gains releaseRules with { "scope": "website", "release": false } ahead of the default rules.

## Test plan

- website/test/latest-release.test.js with node --test, written first and run to fail before src/scripts/latest-release.js existed:
  - pickDownloadAsset returns the Honeycrisp-1.0.1.zip asset from a real v1.0.1 asset list that also holds appcast.xml and Honeycrisp-1.0.1.zip.sha256.
  - pickDownloadAsset returns null for an empty list and for a list with no matching name.
  - describeRelease returns { version: "v1.0.1", url: <zip url> } for the real payload shape, and null when the tag or a usable asset is missing.
- website/test/dist.test.js asserts the built page after npm run build (and skips without one): the five apps in README order, the README privacy sentence, the releases/latest link, the mynameischristian.com credit, no occurrence of "brew", a canonical URL of https://honeycrisp.app/ with no project-page base path, and Plausible initialized for honeycrisp.app. The domain and analytics assertions were written first and run red against the project-page build.
- Nothing here is TCC-gated; the Swift test suite is untouched and must stay green.

## Acceptance criteria

- npm run build then npm test passes inside website/ with all eight tests.
- dist/index.html contains Mail, Reminders, Calendar, Messages, and Contacts in README order, the sentence fragment "the only record kept is a local activity list you can clear", the "Why I built this" story word for word, a link to https://github.com/christianpatrick/honeycrisp/releases/latest, the credit link to https://mynameischristian.com/, and no occurrence of "brew".
- The page is canonical at https://honeycrisp.app/, the shipped JS initializes Plausible for honeycrisp.app, and no secret or repository variable is required anywhere.
- website/src/assets contains only christian.jpg and the fonts; the favicon and inline icons come from the repository's assets/ folder.
- swift build at the repo root is unaffected, and a push to main that touches only website/** runs the Pages workflow and produces no app release.
- The one manual step is documented in the pull request: GitHub Pages must be set to deploy from GitHub Actions if the workflow's enablement call cannot do it itself, and honeycrisp.app must exist as a site in the Plausible account.
