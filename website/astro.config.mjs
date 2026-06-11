// @ts-check
import { defineConfig } from "astro/config";

// The site lives at the root of honeycrisp.app, the custom domain set in
// the repository's Pages settings. GitHub redirects the old
// christianpatrick.github.io/honeycrisp address here on its own.
export default defineConfig({
  site: "https://honeycrisp.app",
});
