// The one network call the website makes: ask GitHub for the latest release
// so the download button can point straight at the zip instead of the
// releases page. Pure logic only; the page wires it to the DOM and falls
// back to the static releases/latest link when anything here returns null.

const downloadName = /^Honeycrisp-.+\.zip$/;

export function pickDownloadAsset(assets) {
  if (!Array.isArray(assets)) return null;
  const match = assets.find(
    (asset) => asset && typeof asset.name === "string" && downloadName.test(asset.name),
  );
  return match ?? null;
}

export function describeRelease(release) {
  if (!release || typeof release.tag_name !== "string" || release.tag_name === "") {
    return null;
  }
  const asset = pickDownloadAsset(release.assets);
  if (!asset || typeof asset.browser_download_url !== "string") {
    return null;
  }
  return { version: release.tag_name, url: asset.browser_download_url };
}
