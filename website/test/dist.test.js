import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// Assertions against the built page, so CI runs the build before npm test.
// Locally, without a build, these skip instead of failing.
const distIndex = fileURLToPath(new URL("../dist/index.html", import.meta.url));
const skip = existsSync(distIndex) ? false : "no dist/index.html, run npm run build first";

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
