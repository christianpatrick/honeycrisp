// @ts-check
import { defineConfig } from "astro/config";

// The site deploys to GitHub Pages as a project page, so it lives under
// /honeycrisp. A custom domain later only needs site and base changed here.
export default defineConfig({
  site: "https://christianpatrick.github.io",
  base: "/honeycrisp",
});
