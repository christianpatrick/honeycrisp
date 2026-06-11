# HC-040: Plausible analytics and the honeycrisp.app domain

## Why

Christian asked for two things after HC-039 shipped the letter: visitor numbers through Plausible's npm tracker, and the site's real home, honeycrisp.app, which is already configured as the custom domain in the repository's Pages settings. Plausible fits the brand because it is cookieless and stores no personal data, and the site ID it needs is the public domain, not a secret, so nothing sensitive enters the repository or its settings.

## Scope

- Serve the site at the root of https://honeycrisp.app: site updated, the /honeycrisp base path removed, canonical and social URLs following along.
- @plausible-analytics/tracker initialized for honeycrisp.app with automatic pageviews and outbound link tracking, plus a Download custom event on the download button carrying the release URL.
- AGENTS.md updated: the site's address, and the analytics stance changed from none to cookieless Plausible.

## Out of scope

- A Plausible proxy, self-hosted endpoint, or adblock evasion of any kind.
- Goals and dashboard configuration inside Plausible itself (one click there to surface the Download goal).
- A www subdomain or any DNS work; GitHub redirects the github.io URL to the custom domain on its own.

## Design

- astro.config.mjs: site https://honeycrisp.app, no base. Asset and canonical URLs derive from it, so nothing else moves.
- A second small script in index.astro: init({ domain: "honeycrisp.app", outboundLinks: true }), then a click listener on the download link that calls track("Download", { props: { url } }). captureOnLocalhost stays default false, so dev and preview sessions are never counted.
- The domain is hardcoded because it is public by design (it ships in every page's source) and now settled. No secret, no Actions variable, no workflow change.

## Test plan

- Extend test/dist.test.js, failing first against the HC-039 build:
  - the canonical link and og:url point at https://honeycrisp.app/ and the old project-page base is gone from the HTML.
  - the built output initializes Plausible for honeycrisp.app (a domain: "honeycrisp.app" literal in the shipped JS).
- npm test green after the rebuild, and the page still renders over a local preview.

## Acceptance criteria

- npm run build then npm test passes inside website/.
- dist/index.html is canonical at https://honeycrisp.app/ with no /honeycrisp/ asset paths.
- The shipped JS initializes Plausible for honeycrisp.app and tracks the Download event with the release URL.
- No secret or repository variable is required anywhere.
