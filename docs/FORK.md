# Maintaining this fork (codewise26/toknotch)

This repository is a **fork** of [ReffWu/toknotch](https://github.com/ReffWu/toknotch) (MIT).
Upstream credit stays in [LICENSE](../LICENSE), the About window, and [README.md](../README.md).

## Repository URLs in the app

- **This fork:** `ForkMetadata.repository` → `codewise26/toknotch`
- **Upstream:** `ForkMetadata.upstreamRepository` → `ReffWu/toknotch`

Settings footer and About link to this fork’s GitHub.

## Sparkle updates (before your first release)

Do **not** reuse upstream’s EdDSA public key. For your own `appcast.xml`:

1. Run `make test` (fetches Sparkle).
2. Run `make sparkle-keys` once; copy the printed **public** key into `project.yml` → `SUPublicEDKey`.
3. Run `xcodegen generate` (or `make gen`) so `Sources/Info.plist` stays aligned.

`SUFeedURL` is already set to:

`https://github.com/codewise26/toknotch/releases/latest/download/appcast.xml`

Until `SUPublicEDKey` is set, **Check for Updates** stays hidden (`Updater.isConfigured` is false).

## Publishing (when you are ready — not required for a code push)

### Local dmg only (no Apple Developer account)

```sh
make dmg-adhoc
```

Output: `build/adhoc-dmg/TokNotch.dmg` (ad-hoc signed). Use **Right-click → Open** on first launch. Not for wide distribution.

### Signed + notarized dmg (for others to install)

1. Enroll in the [Apple Developer Program](https://developer.apple.com) and create a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates).
2. Run `make release` — the script picks the first **Developer ID Application** identity in your keychain, or set:
   ```sh
   export RELEASE_IDENTITY='Developer ID Application: Your Name (TEAMID)'
   export RELEASE_TEAM=TEAMID
   make release
   ```
3. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
4. `make publish` uploads the dmg and `appcast.xml` to GitHub (`codewise26/toknotch`).

See [RELEASING.md](RELEASING.md) for the full chain.

## Removed from this fork

- **More from Reff Wu** catalog (`MoreApps.swift`) — upstream promo list is not shown in Settings.
