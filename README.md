# Tether

An SSH terminal for iPhone and iPad, built with SwiftUI and [xtool](https://github.com/xtool-org/xtool).

## Features

- **Servers**: saved hosts with groups, search, duplicate, a startup command and a per-server theme
- **Sessions**: several live sessions at once. Leave a terminal and come back with its scrollback intact. Reconnect with one tap.
- **Terminal**: xterm-256color via SwiftTerm, with the keyboard accessory row (Esc, Ctrl, Tab, arrows, F-keys), mouse reporting, OSC 52 clipboard and links
- **Keys**: generate Ed25519 / ECDSA P-256 on the device, or import OpenSSH/PEM keys. Copy or share the public key. Private keys are kept in the Keychain.
- **Host key verification**: trust on first use, a loud warning when a key changes, and a Known Hosts manager
- **Clips**: one-tap commands in a bar under the terminal, global or per server
- **Themes**: Harbor, Ember, Phosphor, Paper and Dusk, plus font size, Option-as-Meta and haptic bell

## Install

Add this source in SideStore or AltStore:

```
https://raw.githubusercontent.com/crazyquark/tether/main/source.json
```

Or download `Tether.ipa` from the [latest release](https://github.com/crazyquark/tether/releases/latest).

## Build

```sh
xtool dev build          # unsigned .app in xtool/
xtool auth login         # once, with your Apple ID
xtool dev                # build, sign, install and launch on a connected device
```

## Release

```sh
scripts/release.sh 1.0.1 "What's new"
```

This builds the .ipa, bumps the version in `Info.plist`, creates the GitHub release, and adds the release to `source.json`.

## Layout

| File | Role |
| --- | --- |
| `SSHConnection.swift` | UI-agnostic SwiftNIO SSH transport: connect, auth, PTY shell, resize |
| `SSHSession.swift` | Binds a connection to a SwiftTerm `TerminalView`, prompts and state |
| `KeyManager.swift` | Key generation, OpenSSH/PEM import, fingerprints |
| `Store.swift` | JSON persistence (secrets go to the Keychain) |
| `Vendor/SwiftTerm` | SwiftTerm 1.20.0. Its manifest is patched so the iOS sources build on a Linux host. |

## Tests

`Tests/LinuxHarness/run.sh` starts a throwaway sshd on 127.0.0.1:2222. It then drives the real
`SSHConnection` and `KeyManager` against that server: key import, auth, PTY size, TERM, resize,
host-key rejection and error messages.

## Limitations

- RSA keys and passphrase-protected keys are not supported (swift-nio-ssh only does Ed25519/ECDSA)
- Mosh, port forwarding, jump hosts and iCloud sync are not built yet
- iOS suspends sockets in the background, so long-idle sessions drop and need Reconnect
