# Honeycrisp
*A fast, private, and transparent MCP server for your Apple apps.*

## The short version

Honeycrisp is a small menu bar app with a bundled `honeycrisp` command line bridge for any MCP client.

- **It is fast and native.** It speaks to the system frameworks the apps already use, so requests come back right away with real, structured data instead of scraped text.
- **It is completely private.** Everything stays on your Mac. Nothing is uploaded, ever, and the only record kept is a local activity list you can clear. Honeycrisp only sees the one thing you ask for, the moment you ask for it.
- **It works with any assistant.** Any MCP client can use it, so you are not locked into a single app or vendor.

## What it can reach today

Honeycrisp speaks to five of the apps I live in every day. Each one is a real, first-class connection rather than a thin wrapper.

| App | What Honeycrisp can do |
| --- | --- |
| <img src="assets/app-icons/mail.svg" width="20" align="center"> **Mail** | Pull the thread you half remember, summarize it, draft a reply that sounds like you, and mark it read when you are done. |
| <img src="assets/app-icons/reminders.svg" width="20" align="center"> **Reminders** | Check what is due today, capture the thing you just thought of, and tick items off in the conversation. |
| <img src="assets/app-icons/calendar.svg" width="20" align="center"> **Calendar** | See what is on today, look ahead at the week, and put new events on the books. |
| <img src="assets/app-icons/messages.svg" width="20" align="center"> **Messages** | Catch up on the threads you missed and send a reply without reaching for your phone. |
| <img src="assets/app-icons/contacts.svg" width="20" align="center"> **Contacts** | Look someone up, fix a misspelled name, or save a new face the moment it comes up. |

> [!TIP]
> If there is an app you wish Honeycrisp could communicate with, [open an issue](https://github.com/christianpatrick/honeycrisp/issues/new) and tell me which one!

## Install

The easiest way to get it is through the [releases page](https://github.com/christianpatrick/honeycrisp/releases) and dropping it in your Applications folder.

Honeycrisp works with any MCP client. You point the client at the `honeycrisp serve` command and it does the rest. Here is an example setup:

### Claude Desktop

Add Honeycrisp to your client config, then restart the app.

```jsonc
// ~/Library/Application Support/Claude/claude_desktop_config.json
{
  "mcpServers": {
    "honeycrisp": {
      "command": "honeycrisp",
      "args": ["serve"]
    }
  }
}
```

### Any other MCP client

Every other client follows the same shape. Register a server, set the command to `honeycrisp`, and pass `serve` as the argument. If your client lists servers in a UI, add one pointing at the Honeycrisp binary.

Clients that speak HTTP can skip the bridge and talk to the menu bar app directly:

```sh
claude mcp add --transport http honeycrisp http://127.0.0.1:41117/mcp
```

Either way, every request flows through the one app you granted access to, shows up in its activity list, and obeys the permissions you set in the panel.

## Configuration

By default Honeycrisp exposes all five apps in read-only mode. You can narrow that down with flags on the `serve` command or in the menu bar app directly.

| Option | Default | What it does |
| --- | --- | --- |
| `--apps` | `all` | Comma separated list of apps to enable, for example `mail,reminders`. |
| `--read-only` | `false` | Lets Honeycrisp read but never send, reply, or change anything. |
| `--port` | `stdio` | Serve over a local port instead of standard input and output. |

The first time Honeycrisp touches an app, macOS asks you to grant access to that app, the same prompt you would see for any other software. You stay in control of every permission.

## How it works, and why it is private

Most tools like this drive your apps with AppleScript, spinning up a process and parsing loose text for every request. Honeycrisp speaks to the system frameworks directly instead, so the same request that used to crawl now comes back in a blink, with nothing brittle left to break.

> **Everything stays on your Mac.** Nothing is uploaded, ever. The only record Honeycrisp keeps is the activity list you can open from the menu bar, it lives on your Mac, and you can clear it whenever you like.

There is no account, no cloud, and no telemetry. The only thing Honeycrisp reaches out for is its own updates: it checks a version file so it can tell you when a new release is ready, it sends nothing about you, and you can switch it off in Settings. Everything else works with your Mac offline, because the only machine involved is the one in front of you.

## Why I built this

I love using Apple apps personally and have built great workflows over the years to get the most out of them. As agentic workflows became a daily driver professionally, I wanted that same power using the apps I know and love.
 
After trying several MCP options for Apple, I ran into performance issues: reading and updating data inside apps was slow, and would often lock up an app entirely. Even worse, I had no clear view of what those MCPs could actually see or do on my behalf.
 
So Honeycrisp is here to be your fast, private, and transparent helper. It follows the MCP standard, so you can use it with any model you choose. It keeps a local-only log of every action it takes and lets you fine-tune permissions with a single click.
 
Just remember that while Honeycrisp doesn't upload your data anywhere, it's only as private as the model provider you choose. For a fully private setup, pair it with a local model running in something like Ollama or LM Studio, so nothing ever leaves your Mac.
 
I love eating a good Honeycrisp apple, and now my Mac seems to enjoy it too. :)

## Contributing and requesting apps

Honeycrisp is early and growing. The most useful thing you can do is tell me which app you want next, so if there is one you are missing, [open an issue](https://github.com/christianpatrick/honeycrisp/issues/new) and describe how you would use it. If you would rather build it yourself, pull requests are genuinely welcome, and the app integrations are designed to be added one at a time.

Please read the [contributing guide](CONTRIBUTING.md) before you start, and be kind in the issue tracker. This is a small project made with care, and I would like it to stay that way.

## License

Honeycrisp is free and open source under the [MIT license](LICENSE). Feel free to use it, contribute to it, or fork it.

--

*Honeycrisp is an independent project and is not affiliated with, endorsed by, or sponsored by Apple Inc. Apple, macOS, and the names of Apple apps are trademarks of Apple Inc.*
