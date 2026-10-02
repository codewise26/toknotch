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

1. Set your **Developer ID** and team in `Scripts/release.sh` (replace upstream’s signing identity).
2. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
3. `make publish` builds the dmg, generates `appcast.xml`, and creates a GitHub release on `codewise26/toknotch`.

See [RELEASING.md](RELEASING.md) for the full chain.

## Removed from this fork

- **More from Reff Wu** catalog (`MoreApps.swift`) — upstream promo list is not shown in Settings.
