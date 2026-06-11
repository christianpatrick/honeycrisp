# Menu bar screenshots

Drop screenshots of the menu bar app in this folder (jpg or png) and the
letter grows a sideways strip of taped prints after the apps list. No
code change needed: the page globs this folder at build time and stays
clean while it is empty. Whatever lands here is re-encoded to webp at
build, so jpg sources are fine.

Use these names so the order and the handwritten captions line up:

- 01-activity.jpg
- 02-permissions-simple.jpg
- 03-permissions-advanced.jpg
- 04-status.jpg

A new name still works; it falls back to a caption made from the
filename. Captions and alt text live in src/pages/index.astro.
