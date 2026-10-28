# Security policy

Honeycrisp runs on your own Mac and is trusted with personal data (Mail, Messages, Contacts, Calendar, and Reminders) and with sending mail and messages after you approve each one. Security reports are taken seriously and are genuinely appreciated.

## Reporting a vulnerability

Please report security issues privately through GitHub, using **Report a vulnerability** on the repository's [Security tab](https://github.com/christianpatrick/honeycrisp/security/advisories/new). Do not open a public issue or pull request for a security problem.

It helps to include what you found, the steps to reproduce it, the version (the panel footer or `honeycrisp version`), and what someone could do with it. A small proof of concept is welcome.

You can expect an acknowledgement within a few days. When a fix is ready it ships in a new release, and the advisory is published with credit to you unless you would rather stay anonymous. Please give a reasonable window to fix the issue before any public disclosure.

## Supported versions

Honeycrisp is early and ships from a single release line, so security fixes land in the latest release. Please update to the newest version and confirm the issue still reproduces before reporting.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No |

## What is in scope

A vulnerability is anything that lets data leave your Mac, or lets an action happen, in a way the design does not intend. Reports worth sending include:

- Reading or sending data without the permissions or the per-request approval allowing it.
- A way to reach the local server that bypasses its loopback binding, its tunnel and rebinding guard, or its optional bearer token.
- A way past remote access's OAuth or passkey sign-in: a token, code, or passkey check that accepts something it shouldn't, a redirect to a place the client never registered, or a page that runs script a client name smuggled in.
- An update that installs without a valid EdDSA signature, or any tampering with the update path.
- A write to a data store that another app owns, which Honeycrisp must never do.
- Any path that exfiltrates the local activity log or personal data off the machine.

## What is by design, not a vulnerability

These are intentional and are not security issues on their own:

- The local MCP server binds to loopback only (127.0.0.1) and refuses requests that arrive through a proxy or under another host name. An optional bearer token gates access.
- Remote access is off by default. When you turn it on, a second loopback port serves OAuth and MCP to a tunnel you run, and every remote client has to be allowed with your passkey. Anyone who can reach your tunnel can see the sign-in page and register a client, and a remote client you allow gets the same access your permission settings give every client.
- Outbound actions whose effect leaves your Mac (sending mail, sending a message) require an explicit approval every single time, even when their permission is on.
- Honeycrisp keeps a local activity log and reads it locally; it has no account, server, or telemetry. Remote access uses a tunnel you run, never a server of Honeycrisp's.
- The one outbound request is the Sparkle update check, which fetches a signed appcast over HTTPS, sends no personal data, and can be turned off in Settings.

Thank you for helping keep Honeycrisp and the people who use it safe.
