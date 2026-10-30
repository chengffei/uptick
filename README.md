# Uptick — Mac App Updater

A free, open-source way to see which of your Mac apps have updates, as a successor to MacUpdater.

> **Status: early.** The app finds updates, verifies uncertain ones, and installs them. English and Simplified Chinese.

## Install

1. Download [Uptick-0.1.0.dmg](https://github.com/chengffei/uptick/releases/latest/download/Uptick-0.1.0.dmg) and drag Uptick into Applications.
2. Uptick is signed but not notarized, so macOS blocks the first launch. Open it, close the warning, then click **Open Anyway** in *System Settings › Privacy & Security*. Or run this once in Terminal and open Uptick as usual:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Uptick.app
   ```

Requires macOS 14 or later.

## How it works

Uptick reads the version of every app in `/Applications` and `~/Applications`, then asks the app's own update channel for the latest release:

1. **Mac App Store**: Apple's public lookup API, using the Mac build's record rather than the iPhone one.
2. **Sparkle**: the app's appcast feed, compared by build number the same way Sparkle does.
3. **Electron**: the `latest-mac.yml` feed declared by electron-updater.
4. **Homebrew Cask**: Homebrew's public cask list, matched by app name.

When a source uses a different numbering than the app (Homebrew says `8.3.14`, the app says `147.0.7727.149`), the result is marked for review instead of reported as an update. `uptick verify` then downloads the package, reads the app inside, checks that it comes from the same developer, and remembers the real version so the question never comes up again.

## Installing updates

Pressing **Update** downloads the package, checks it holds the same app signed by the same developer with a valid signature, quits the app if it is running, moves the old copy to the Trash, and puts the new one in its place. Mac App Store apps open their App Store page instead, because macOS no longer lets other apps install App Store updates. Packages that ship as a `.pkg` are saved to Downloads and opened in Installer.

macOS may ask you to allow Uptick under **Privacy & Security › App Management** the first time it replaces an app.

## Building

Requires macOS 14 or later and Xcode.

```sh
scripts/bundle.sh --open         # builds and opens build/Uptick.app
scripts/make-release.sh          # universal release → dist/Uptick-<version>.dmg and .zip
```

The same engine is available on the command line:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
.build/debug/uptick              # every app with installed and latest version
.build/debug/uptick --updates    # only apps with an update
.build/debug/uptick verify Lark  # download the update and confirm what it really is
.build/debug/uptick install Lark # install it
```

## Contributing

Contributions are welcome. Code contributions require agreeing to the [Contributor License Agreement](CLA.md). Reports of wrong versions need no agreement: open an issue with the app name, the version Uptick showed, and the version you actually have.

## License

[GPL-3.0](LICENSE)
