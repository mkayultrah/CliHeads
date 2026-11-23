# CliHeads

Fb Messenger style chat heads for your favorite AI Agents.

Each chat head is a CLI session running in the background. Click a head to open the chat, drag it around and it snaps to the screen edge, drop heads on each other to stack them, fling one at the X to close it. When an agent replies you get the little preview bubble and an unread badge.

Works with:

- Claude Code (`claude`)
- Codex (`codex`)
- Gemini CLI (`gemini`)
- Grok (`grok`)

Each one runs through its own CLI, so install it and sign in from Terminal first. No API keys go through the app. CliHeads finds the CLIs on the same PATH your login shell uses, so installs through Homebrew, npm, nvm, bun or volta all work. CLIs it can't find show as "not installed" in the menu.

## Features

- streaming replies with thinking shown above them
- click a code block to copy it
- paste or drop images into the chat
- shift+tab cycles permission modes (whatever the CLI supports)
- type while it's working and the message queues for after the turn
- `/resume` to pick an older conversation, `/clear` to start fresh
- Full CLI button swaps the chat for the real terminal UI, and back
- new heads pick up the latest conversation for that folder
- launch at login from the menu bar icon
- respects `CLAUDE_CONFIG_DIR` if you keep Claude's config somewhere else

## Build

Needs macOS 14 or newer and the Xcode command line tools (`xcode-select --install`).

```sh
./build.command
```

That builds `dist/CliHeads.app`, quits any running copy and opens the new one. To just build without opening it:

```sh
./Scripts/make-app.sh               # this Mac's arch, signed ad hoc
UNIVERSAL=1 ./Scripts/make-app.sh   # arm64 + x86_64
```

Heads, history and positions are saved in `~/Library/Application Support/CliHeads/heads.json`.

## Release

Needs a Developer ID Application certificate. Store notary credentials once with `xcrun notarytool store-credentials`, then:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=your-profile \
./Scripts/release.sh
```

You get a signed, notarised, universal `dist/CliHeads-<version>.zip`. Leave out `NOTARY_PROFILE` to skip notarising. The version comes from `Info.plist`.

## Tests

```sh
for t in syntax protocol agents magnets previews stacks; do ./Scripts/test-$t.sh; done
```

## Thanks

The spring feel is based on Facebook's [Rebound](https://github.com/facebookarchive/rebound) (BSD). Also looked at [brutella/chatheads](https://github.com/brutella/chatheads) and [BubbleControl-Swift](https://github.com/cemolcay/BubbleControl-Swift).

## License

MIT
