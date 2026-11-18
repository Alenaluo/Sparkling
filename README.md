# Sparkling ✦

Idea notes that live in your Mac's menu bar. Press `⌥⇧Space` in any app to open the capture panel, jot down the idea, pick a project (click a tag, press `⌘1–9` or `Tab`, or type `@` in the text to autocomplete), and press `⏎` to save. Ideas without a project go to "Unsorted".

Each project is a folder and each idea is a Markdown file. Everything lives in `~/Documents/Sparkling` by default, so you can open, sync and back it up with Obsidian, VS Code or Finder.

**Clipboard history** (since 0.1.2): press `⌥⇧V` to browse recently copied text, screenshots and files. `⏎` copies an item back; `⌘S` saves it as an idea (images are copied into the project's `assets/`, files are saved as links). The last 50 items are kept by default, stored only on this Mac (`~/Library/Application Support/Sparkling/clipboard/`) and never uploaded. Content that password managers mark as sensitive is always skipped. You can also browse it from "Clipboard" in the main window's sidebar.

**Chinese / English** (since 0.1.2): choose Follow System, 中文 or English under Settings › General › Language. Takes effect after a restart.

## Download and install

Requires macOS 14 Sonoma or later, on Apple silicon or Intel.

1. Download the latest `Sparkling-x.y.z.dmg` from [Releases](../../releases).
2. Open it and drag **Sparkling** into Applications.
3. The first launch may say the developer cannot be verified, or that Apple cannot check it for malicious software. That is because the app is not notarized by Apple (a paid program); it is not malware. Allow it either way:
   - **System Settings › Privacy & Security**, scroll down to Security, click "Open Anyway" and confirm with your password; or
   - run this once in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/Sparkling.app
     ```
4. The icon appears in the menu bar. Follow the onboarding to pick your notes folder.

### FAQ

- **The shortcut does nothing**: another app (Raycast, Alfred, ChatGPT, …) has most likely taken the same key. Click the menu bar icon › "Settings…" and change "Capture shortcut" on the General tab. The clipboard's `⌥⇧V` is changed on the Clipboard tab.
- **I don't want my clipboard recorded**: turn off "Record clipboard" under Settings › Clipboard, or add apps to "Don't record these apps". "Clear Clipboard History…" deletes everything recorded.
- **Open at login**: turn it on in Settings.
- **Uninstall**: quit the app and drag `/Applications/Sparkling.app` to the Trash. Your idea files stay in your notes folder and are not deleted.

## Development

### Build and run

```bash
swift build && swift test          # build + unit tests (IdeaCoreTests, IdeaUITests)
./scripts/run.sh                   # dev run: data root ~/IdeaNotes-dev, log in build/run.log
SPARKLING_SKIP_ONBOARDING=1 ./scripts/run.sh   # skip onboarding
./scripts/bundle.sh release --install           # release build, installed to /Applications and launched
./scripts/package.sh                            # distributable dist/Sparkling-<version>.dmg (universal binary)
SPARKLING_LANG=en swift test                    # run the English-UI tests
```

- Data root: the `SPARKLING_ROOT` environment variable, then Settings, then `~/Documents/Sparkling` (0.1 used `~/Documents/IdeaNotes`; it is renamed automatically on first launch). Avoid `~/Documents` during development: ad-hoc signing changes identity on every build, so the Documents permission prompt keeps coming back.
- Signing: `bundle.sh` uses `SPARKLING_SIGN_ID` first, then a self-signed "Sparkling Dev" certificate from the keychain (Keychain Access › Certificate Assistant › Create a Certificate, type Code Signing), and falls back to ad-hoc. A stable identity keeps the Documents permission and Open at Login working. `CSSMERR_TP_NOT_TRUSTED` for the self-signed certificate is expected and harmless on your own Mac.
- Logs: `/usr/bin/log stream --predicate 'subsystem == "local.sparkling"' --level debug` (in zsh `log` is a builtin, so use the full path). Includes hotkey-to-focus timing, each saved file name and key-handling decisions.

### ideactl (command-line debugging)

```bash
swift run ideactl --root ~/IdeaNotes-dev repos
swift run ideactl --root ~/IdeaNotes-dev repo add "Player Rewrite" --short pr
swift run ideactl --root ~/IdeaNotes-dev save "Long-press right side for 2x speed #interaction" --repo "Player Rewrite"
swift run ideactl --root ~/IdeaNotes-dev match pr      # @ autocomplete results
swift run ideactl --root ~/IdeaNotes-dev grep speed    # search across projects
```

### Layout

- `Sources/IdeaCore`: pure logic (front matter, storage, pinyin matching, `@` parsing, tag selection, key decisions, search, clipboard history, Chinese/English strings), all unit-tested.
- `Sources/IdeaUI`: AppKit + SwiftUI UI (hotkeys, capture panel, clipboard panel, HUD, library, settings, onboarding).
- `Sources/Sparkling`: app entry point; `Sources/ideactl`: command-line tool.
- `scripts/make-icon.swift`: renders the app icon SVG into `Resources/AppIcon.icns`.

### Known limitations

- External edits are not picked up live: they are read after a restart, when opening the All Ideas window, or via File › Reload Folder.
- Pinyin comes from the system's per-character conversion, so characters with several readings may be off (e.g. 重构 gets the default short code `bfqzg`). Common cases have alternates, so `@bfqcg` also matches.

### Texture assets

`Sources/IdeaUI/TextureAssets.swift` is generated from the SVG textures in the design files (not in this repository). The SVGs are embedded as-is, and `#37352F` is replaced with the theme's text color at load time. When the assets change, rerun the generator script from the parent `Tools/` directory, or paste the new SVG into the matching constant.

### Releasing

1. Bump `CFBundleShortVersionString` (e.g. `0.1.4`) and `CFBundleVersion` (+1) in `Resources/Info.plist`.
2. Run `./scripts/package.sh` to get `dist/Sparkling-<version>.dmg` and its `.sha256`.
3. Commit and tag: `git commit -am "v0.1.4" && git tag v0.1.4 && git push --tags`.
4. On GitHub › Releases › Draft a new release, pick the tag, attach the dmg and sha256, and publish.

To spare users the "Open Anyway" step, join the Apple Developer Program ($99/year) and sign and notarize with a Developer ID certificate. `package.sh` already supports this; see the comments at the top of the script.

## License

MIT, see [LICENSE](LICENSE).
