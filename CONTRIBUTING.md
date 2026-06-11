# Contributing to Honeycrisp

Thanks for wanting to help. Honeycrisp is a small project made with care, and contributions that keep it fast, private, and native are genuinely welcome.

## What you need

- macOS 15 or later. Development and verification happen on macOS 26.
- Xcode 26 or later with the command line tools installed.

## Build and test

```sh
swift build
swift test
```

Tests that touch the real apps are gated, because they need macOS permission grants:

```sh
HONEYCRISP_INTEGRATION=1 swift test
```

The first gated run will make macOS ask for the relevant permissions. That is expected.

## How work happens here

Read [AGENTS.md](AGENTS.md) first. The short version:

- Spec first. Every task starts as a spec in [.specs/](.specs/README.md) before any code.
- Test-driven. The failing test comes first, you watch it fail, then you make it pass.
- Meaningful tests only. Behavior through public API, system frameworks behind protocols with fakes.
- [Conventional commits](https://www.conventionalcommits.org/en/v1.0.0/).
- Everything is native Swift, including developer tooling.
- Hard lines: no telemetry of any kind, loopback networking only, never write a data store another app owns, and never spawn osascript.
- Copy rules: full sentences, sentence case, no em-dashes, no emoji.

## Requesting an app

The most useful contribution is telling me which app you want Honeycrisp to reach next and how you would use it. Open an issue and describe the moment you needed it. The integrations are designed to be added one at a time, so a good description is most of the work.

Be kind in the issue tracker. I would like this to stay a pleasant corner of the internet.
