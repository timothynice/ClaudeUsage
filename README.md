# UsageRing

Claude Code usage limits in your macOS menu bar.

A small ring in the menu bar shows how much of your **5-hour window** you've
used, color coded (green → yellow → orange → red). Click it for the full
picture — the same numbers as Claude Code's *"Your usage limits"* panel:

- **5-hour limit** with reset countdown
- **Weekly · all models**
- **Weekly · Fable / Opus** (whatever windows your plan reports)
- **Usage credits**

No Electron, no dependencies — a single native SwiftUI executable.

## Install

[![Build status](https://github.com/<OWNER>/<REPO>/actions/workflows/ci.yml/badge.svg)](https://github.com/<OWNER>/<REPO>/actions/workflows/ci.yml)

Requirements: macOS 14+, Xcode (or Command Line Tools with Swift 5.9+), and a
machine that's signed in to **either** the Claude desktop app **or** the Claude
Code CLI (`claude`). Most people already have the desktop app — that's enough,
and it means **no separate sign-in for this tool**.

```bash
git clone https://github.com/<OWNER>/<REPO>.git && cd <REPO>
make install      # builds, copies to /Applications, launches
```

Other targets: `make run` (run from `dist/` without installing), `make test`,
`make uninstall`, `make clean`.

> Distributing the built `.app` directly (zip/AirDrop/Slack) mostly works, but
> Gatekeeper quarantines ad-hoc-signed downloads. Building from source is the
> intended path for the team; otherwise recipients need
> `xattr -dr com.apple.quarantine UsageRing.app`.

## How it works

UsageRing polls every 60 seconds (configurable:
`defaults write com.usagering.app refreshSeconds 30`) and has **two data
sources**, tried in order:

### 1. Desktop-app session (primary — no sign-in)

The Claude desktop app is already logged in to claude.ai. It's an Electron app,
so its cookies live in a SQLite DB (`~/Library/Application Support/Claude/
Cookies`) with each value AES-encrypted under a key in the `Claude Safe Storage`
keychain item (Chromium's standard `OSCrypt` scheme). UsageRing:

1. Reads the `Claude Safe Storage` key via `/usr/bin/security`.
2. Derives the AES key (`PBKDF2-HMAC-SHA1(key, "saltysalt", 1003, 16)`) and
   decrypts the `claude.ai` cookies — the `sessionKey` and Cloudflare clearance.
3. Picks the active org from the `lastActiveOrg` cookie (falling back to the
   paid/stripe org).
4. Calls the claude.ai web endpoint the app's own usage screen uses:

```
GET https://claude.ai/api/organizations/{org}/usage
Cookie: sessionKey=…; cf_clearance=…
```

This returns a clean `limits` array (session / weekly-all / per-model weekly)
plus a `spend` block — exactly what the panel renders. Cookies are re-read every
poll, so when the desktop app rotates its session or Cloudflare clearance,
UsageRing picks it up automatically.

> **Why not `curl`?** Cloudflare bot-filters curl's TLS fingerprint and returns
> `403 "Just a moment…"`. Native `URLSession` (what the app uses) presents a
> normal macOS fingerprint and passes with the replayed `cf_clearance`.

### 2. OAuth token (fallback — for CLI-only machines)

If the desktop app isn't installed/signed in, UsageRing falls back to the OAuth
token Claude Code stores in `Claude Code-credentials`, polling
`GET https://api.anthropic.com/api/oauth/usage`. On expiry it refreshes via
`POST https://console.anthropic.com/v1/oauth/token` and writes the rotated
(single-use) tokens back to the keychain, keeping the CLI and this app in sync.
This path needs a one-time `claude auth login` — click the panel's warning to
start it. A dead refresh token is fingerprinted and never retried (see
`RefreshGate`).

### Security notes

- Everything stays on your machine. Requests go only to `claude.ai` /
  `api.anthropic.com` / `console.anthropic.com`. No cookie, token, or usage
  value is logged or written anywhere but back to the keychain it came from.
- All keychain access goes through `/usr/bin/security` — the Apple-signed binary
  the item's ACL already trusts — so once you click **Always Allow** on the
  `Claude Safe Storage` prompt the first time, it's silent thereafter, even
  across app updates (the ACL trusts `security`, not UsageRing's changing
  ad-hoc signature).
- Both endpoints are undocumented (the ones Claude's own UIs call). If Anthropic
  changes them, the ring shows an attention state and the panel explains; the
  parser tolerates new/renamed windows.

## Troubleshooting

- **"Keychain access needed"** — approve the `Claude Safe Storage` prompt and
  choose **Always Allow**. This lets UsageRing read the desktop app's session;
  it's a one-time click.
- **"Session needs a refresh"** — the desktop app's Cloudflare clearance went
  stale (usually because the app hasn't run in a while). Open the Claude desktop
  app once and UsageRing recovers on the next poll.
- **Gray ring with an orange dot (CLI-only machines)** — the OAuth fallback
  needs a sign-in. **Click the warning in the panel** and UsageRing opens
  `claude auth login` in Terminal for you; finish the login and the ring lights
  up within ~5 seconds (the app polls fast while it waits). The app never
  handles your credentials itself. *If your work email is slow to deliver the
  login code, you don't need this path at all — just use the desktop app, which
  UsageRing reads directly.*
- **Don't debug the endpoints with `curl`.** Cloudflare bot-filters curl's TLS
  fingerprint on `console.anthropic.com/v1/oauth/token` and returns
  429 "Rate limited" no matter what — it looks exactly like a quota problem
  and isn't. Use URLSession (or this app) to see truthful responses.
- **Launch at login toggle errors** — it needs the installed copy
  (`make install`), not the one running from `dist/`.

## UI reference

| State | Ring |
|---|---|
| < 50% of 5-hour window | green |
| 50–79% | yellow |
| 80–94% | orange |
| ≥ 95% | red |
| No data / needs attention | gray ring, orange center dot (open the panel for details) |

Panel extras: percentage-in-menu-bar toggle, launch at login, manual refresh,
link to claude.ai's usage page, quit.

## Design decisions

- **Server-side truth, not local estimates.** Tools that parse
  `~/.claude/**/*.jsonl` transcripts only estimate; the OAuth usage endpoint
  returns the exact percentages Anthropic enforces, for zero token cost.
- **`security` CLI before Security.framework.** The keychain item's ACL already
  trusts the `security` binary (Claude Code manages the item through it), so
  reads are silent. A differently-signed app using `SecItemCopyMatching` would
  prompt on every rebuild.
- **Refresh + write-back instead of "run `claude` to fix it".** Desktop-app
  users can have a stale CLI keychain entry for weeks (that's how this repo's
  author's machine looked). The app refreshes autonomously and persists the
  rotation so nothing else breaks.
- **Never retry a dead token.** A refresh token the server rejects with
  `invalid_grant` will never work again, so retrying it on every 60s poll would
  send ~1,400 futile requests a day per machine. `RefreshGate` fingerprints the
  refresh token (a one-way hash — the secret is never held or logged) and stops
  attempting until the stored credentials actually change, which is exactly what
  signing in does. Rate limits get a separate, temporary 5→30 min backoff that
  honors `Retry-After`.
- **Tolerant parsing.** Windows are discovered from the response
  (`five_hour`, `seven_day`, `seven_day_*`, future ones) rather than
  hard-coded, and unknown fields are preserved on write-back.

## Project layout

```
Sources/UsageRing/
  UsageRingApp.swift   app entry, MenuBarExtra, menu bar label
  UsageModel.swift     polling loop + published state
  UsageClient.swift    usage/profile fetch + OAuth refresh
  Credentials.swift    keychain/file read + rotated-token write-back
  UsageParser.swift    tolerant response parsing (unit tested)
  StatsView.swift      the click-down stats panel
  RingIcon.swift       menu bar ring rendering
  StatusColor.swift    usage → color thresholds
Tests/UsageRingTests/  parser + credential parsing tests (`make test`)
```
