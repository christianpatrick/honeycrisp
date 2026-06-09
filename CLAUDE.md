# CLAUDE.md

Read AGENTS.md first. It holds the working agreements, architecture decisions, permission model, process rules, and findings log for this repository, and it overrides anything you would otherwise assume.

Two more pointers:

- The product UI and toolset spec lives locally at the spec (gitignored, never committed; see AGENTS.md). the catalog spec defines the apps, actions, and defaults; the panel spec, the onboarding spec, and the canvas spec define the panel, first run, and approval flow.
- .spec holds one spec per task (HC-NNN). Write the spec before the code, and write the failing test before the implementation.
