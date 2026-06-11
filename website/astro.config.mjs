// @ts-check
import { fileURLToPath } from "node:url";
import { defineConfig } from "astro/config";

// The site lives at the root of honeycrisp.app, the custom domain set in
// the repository's Pages settings. GitHub redirects the old
// christianpatrick.github.io/honeycrisp address here on its own.
export default defineConfig({
  site: "https://honeycrisp.app",
  vite: {
    server: {
      fs: {
        // The page imports the brand SVGs from the repository's assets/
        // folder, one level above this project, so let the dev server read
        // the repository root.
        allow: [fileURLToPath(new URL("..", import.meta.url))],
      },
    },
  },
});
