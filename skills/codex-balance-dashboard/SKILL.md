---
name: codex-balance-dashboard
description: Use when installing, running, packaging, troubleshooting, or customizing the native macOS Codex balance floating dashboard that reads local ~/.codex/sessions token_count logs.
---

# 算力码表 Dashboard

Help users install, run, package, troubleshoot, or customize the native macOS Codex balance floating dashboard.

## Guardrails

- Treat `~/.codex/sessions` as private user data.
- Never upload, paste, or summarize raw session logs unless the user explicitly asks and understands the privacy impact.
- Prefer read-only checks. The app and scripts should not write to `~/.codex`.
- The app may write small aggregated device usage snapshots to iCloud Drive; do not copy raw Codex logs there.
- Keep the compact window visually simple: 5-hour quota is blue, 7-day quota is green, and there are no yellow/red warning markers.

## Common Workflows

### Check Environment

Run:

```bash
./skills/codex-balance-dashboard/scripts/check-environment.sh
```

This checks Swift availability and whether the Codex sessions directory exists.

### Build And Launch

Run from the repository root:

```bash
./script/build_and_run.sh
```

It builds the Swift package, creates `dist/算力码表.app`, creates a desktop shortcut when possible, and opens the app.

### Custom Codex Home

If Codex data lives somewhere else:

```bash
CODEX_HOME=/path/to/.codex ./script/build_and_run.sh
```

### Run Tests

```bash
swift test
```

Tests focus on JSONL parsing, reset inference, missing fields, and token daily/monthly aggregation.

### Two Mac Usage Sync

The app compares `MacBook Pro`, `Mac Studio`, and `总算力` by syncing aggregated JSON snapshots through:

```bash
~/Library/Mobile Documents/com~apple~CloudDocs/APP安装包/算力码表/sync
```

Use Git for source code on both Macs; use iCloud only for release packages and the small `macbook-pro.json` / `mac-studio.json` usage snapshots.

Override device detection when needed:

```bash
CODEX_BALANCE_DEVICE_ID=macbook-pro ./script/build_and_run.sh
CODEX_BALANCE_DEVICE_ID=mac-studio ./script/build_and_run.sh
```

### Package Release Zip

```bash
./script/package_release.sh
```

## App Structure

- `Sources/CodexBalanceCore`: read-only JSONL scanning, rate limit parsing, reset countdown formatting, token stats.
- `Sources/CodexBalance`: SwiftUI/AppKit floating window UI.
- `script/build_and_run.sh`: local release app bundling and launch.

## Troubleshooting

- If no data appears, verify `~/.codex/sessions` exists and contains `.jsonl` files.
- If the other Mac line is missing, open 算力码表 once on that Mac and verify iCloud Drive is syncing `APP安装包/算力码表/sync`.
- If percentages look stale, run Codex once and then refresh the app; the dashboard can only show the newest `token_count` event written by Codex.
- If the app cannot launch from Finder, rebuild with `./script/build_and_run.sh`.
- If Gatekeeper blocks a downloaded release, explain that early unsigned builds may require right-click Open, then recommend signed/notarized releases once available.
