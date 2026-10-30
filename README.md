# Uptick — Mac App Updater

A free, open-source way to see which of your Mac apps have updates, as a successor to MacUpdater.

> **Status: early.** Uptick is a command-line tool for now. It finds updates and verifies them; it does not install them yet. A native app is planned.

## How it works

Uptick reads the version of every app in `/Applications` and `~/Applications`, then asks the app's own update channel for the latest release:

1. **Mac App Store**: Apple's public lookup API, using the Mac build's record rather than the iPhone one.
2. **Sparkle**: the app's appcast feed, compared by build number the same way Sparkle does.
3. **Electron**: the `latest-mac.yml` feed declared by electron-updater.
4. **Homebrew Cask**: Homebrew's public cask list, matched by app name.

When a source uses a different numbering than the app (Homebrew says `8.3.14`, the app says `147.0.7727.149`), the result is marked for review instead of reported as an update. `uptick verify` then downloads the package, reads the app inside, checks that it comes from the same developer, and remembers the real version so the question never comes up again.

## Usage

Requires macOS 14 or later and Xcode.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
.build/debug/uptick              # every app with installed and latest version
.build/debug/uptick --updates    # only apps with an update
.build/debug/uptick verify Lark  # download the update and confirm what it really is
```

## Contributing

Contributions are welcome. Code contributions require agreeing to the [Contributor License Agreement](CLA.md). Reports of wrong versions need no agreement: open an issue with the app name, the version Uptick showed, and the version you actually have.

## License

[GPL-3.0](LICENSE)
