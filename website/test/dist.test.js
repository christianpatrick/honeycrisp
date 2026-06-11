import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// Assertions against the built page, so CI runs the build before npm test.
// Locally, without a build, these skip instead of failing.
const distDir = fileURLToPath(new URL("../dist", import.meta.url));
const distIndex = join(distDir, "index.html");
const skip = existsSync(distIndex) ? false : "no dist/index.html, run npm run build first";

// The page plus every built script, for assertions on shipped code.
function builtOutput() {
  const pieces = [readFileSync(distIndex, "utf8")];
  const astroDir = join(distDir, "_astro");
  if (existsSync(astroDir)) {
    for (const name of readdirSync(astroDir)) {
      if (name.endsWith(".js")) pieces.push(readFileSync(join(astroDir, name), "utf8"));
    }
  }
  return pieces.join("\n");
}

test("the letter lists the five apps in README order", { skip }, () => {
  const html = readFileSync(distIndex, "utf8");
  const positions = ["Mail", "Reminders", "Calendar", "Messages", "Contacts"].map((name) => {
    const at = html.indexOf(`>${name}<`);
    assert.notEqual(at, -1, `${name} is missing`);
    return at;
  });
  assert.deepEqual(positions, [...positions].sort((a, b) => a - b), "apps are out of order");
});

test("the letter says what the README says", { skip }, () => {
  const html = readFileSync(distIndex, "utf8");
  assert.ok(
    html.includes("the only record kept is a local activity list you can clear"),
    "the privacy sentence must match the README",
  );
  assert.ok(
    html.includes("https://github.com/christianpatrick/honeycrisp/releases/latest"),
    "the download link must point at the latest release",
  );
  assert.ok(html.includes("https://mynameischristian.com/"), "the maker credit is missing");
  assert.ok(!/brew/i.test(html), "Homebrew must not be mentioned");
});

test("the letter lives at the root of honeycrisp.app", { skip }, () => {
  const html = readFileSync(distIndex, "utf8");
  assert.ok(
    html.includes('rel="canonical" href="https://honeycrisp.app/"'),
    "the canonical URL must be the custom domain",
  );
  assert.ok(!html.includes("/honeycrisp/_astro/"), "the project-page base path must be gone");
});

test("plausible is initialized for honeycrisp.app", { skip }, () => {
  assert.match(
    builtOutput(),
    /domain:\s*["']honeycrisp\.app["']/,
    "the shipped JS must call init with the honeycrisp.app domain",
  );
});
