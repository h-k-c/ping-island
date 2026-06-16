# Homebrew Cask Release Setup

Auralink distributes Homebrew installs from the same notarized DMG that the
GitHub Release and Sparkle release flow already publish.

## Tap

Use a separate tap repository:

```bash
brew tap-new erha19/tap
gh repo create erha19/homebrew-tap --public --source "$(brew --repository erha19/tap)" --push
```

Users can install from that tap with:

```bash
brew tap erha19/tap
brew install --cask ping-island
```

The seed cask lives at `packaging/homebrew/Casks/ping-island.rb`. The release
automation writes the production cask into the external tap as
`Casks/ping-island.rb`.

## GitHub Actions Sync

Set this secret on the main `ping-island` repository:

| Secret | Purpose |
| --- | --- |
| `HOMEBREW_TAP_TOKEN` | GitHub token with write access to `erha19/homebrew-tap` |

Optional repository variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `HOMEBREW_TAP_REPO` | `erha19/homebrew-tap` | Tap repository to update |
| `HOMEBREW_TAP_BRANCH` | `main` | Branch to push |

The release workflow skips Homebrew sync when the GitHub Release is kept as a
draft, marked as a prerelease, or when `HOMEBREW_TAP_TOKEN` is unset. This keeps
the cask from pointing at a private draft asset.

## Local Update

To update a local tap checkout from a generated DMG:

```bash
scripts/update-homebrew-cask.sh \
  --version 0.9.2 \
  --dmg releases/signed/PingIsland-0.9.2.dmg \
  --tap-dir "$(brew --repository erha19/tap)" \
  --no-commit
```

To let the script clone, commit, and push the tap:

```bash
export PING_ISLAND_HOMEBREW_TAP_TOKEN=...
scripts/update-homebrew-cask.sh \
  --version 0.9.2 \
  --dmg releases/signed/PingIsland-0.9.2.dmg \
  --push
```

The script computes the DMG SHA-256, renders the cask, checks Ruby syntax, and
uses the Lore commit format for the tap commit.
