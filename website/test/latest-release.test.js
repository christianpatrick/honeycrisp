import test from "node:test";
import assert from "node:assert/strict";
import { pickDownloadAsset, describeRelease } from "../src/scripts/latest-release.js";

// The shape GitHub returned for the real v1.0.1 release: the app zip sits
// beside the Sparkle appcast and the checksum, and only the zip is the
// download people want.
const v101Assets = [
  {
    name: "appcast.xml",
    content_type: "application/xml",
    browser_download_url:
      "https://github.com/christianpatrick/honeycrisp/releases/download/v1.0.1/appcast.xml",
  },
  {
    name: "Honeycrisp-1.0.1.zip",
    content_type: "application/zip",
    browser_download_url:
      "https://github.com/christianpatrick/honeycrisp/releases/download/v1.0.1/Honeycrisp-1.0.1.zip",
  },
  {
    name: "Honeycrisp-1.0.1.zip.sha256",
    content_type: "application/octet-stream",
    browser_download_url:
      "https://github.com/christianpatrick/honeycrisp/releases/download/v1.0.1/Honeycrisp-1.0.1.zip.sha256",
  },
];

test("pickDownloadAsset picks the app zip and ignores the appcast and checksum", () => {
  const asset = pickDownloadAsset(v101Assets);
  assert.equal(asset.name, "Honeycrisp-1.0.1.zip");
});

test("pickDownloadAsset returns null when nothing matches", () => {
  assert.equal(pickDownloadAsset([]), null);
  assert.equal(pickDownloadAsset([{ name: "appcast.xml" }]), null);
  assert.equal(pickDownloadAsset([{ name: "Honeycrisp-1.0.1.zip.sha256" }]), null);
});

test("describeRelease returns the version label and the direct zip url", () => {
  const release = { tag_name: "v1.0.1", assets: v101Assets };
  assert.deepEqual(describeRelease(release), {
    version: "v1.0.1",
    url: "https://github.com/christianpatrick/honeycrisp/releases/download/v1.0.1/Honeycrisp-1.0.1.zip",
  });
});

test("describeRelease returns null when the payload is unusable", () => {
  assert.equal(describeRelease(null), null);
  assert.equal(describeRelease({}), null);
  assert.equal(describeRelease({ tag_name: "v1.0.1", assets: [] }), null);
  assert.equal(describeRelease({ assets: v101Assets }), null);
});
