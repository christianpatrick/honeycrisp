# Menu bar screenshots

Drop PNG screenshots of the menu bar app in this folder and the letter
grows a sideways strip of taped prints after the apps list. No code
change needed: the page globs this folder at build time and stays clean
while it is empty.

Use these names so the order and the handwritten captions line up:

- 01-activity.png
- 02-permissions-simple.png
- 03-permissions-advanced.png
- 04-status.png

A new name still works; it falls back to a caption made from the
filename. Captions and alt text live in src/pages/index.astro.
