# HC-020: Readable text from HTML-only mail

- Task number: HC-020 (no GitHub issue yet)
- Status: done
- Date: 2026-06-09

## Why

The first live mail_read returned a newsletter with no text/plain part, and the HTML fallback de-tagged it but kept the contents of style blocks plus the layout's whitespace, so the body led with hundreds of lines of CSS soup. Assistants summarize what we hand them; HTML-only mail must come out as prose.

## Scope

- MimeText's HTML stripping removes style, script, and head blocks wholesale before de-tagging, decodes the common entities (nbsp, amp, lt, gt, quot, copy), and collapses the whitespace so the result is one trimmed line per content run.
- Regression coverage through the public fixture path: an HTML-only .emlx whose body must contain the prose, none of the CSS, and no blank-line noise.
- Ships in v0.1.7 alongside HC-019.

## Test plan

Failing first in MailDatabaseTests: a fixture message whose only part is text/html with a style block; the current stripper leaks the CSS into the body.

## Acceptance criteria

- The new fixture test was observed red and passes; the suite stays green.
- A live HTML-only newsletter reads as prose through mail_read on this Mac.
