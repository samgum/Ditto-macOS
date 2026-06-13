# Ditto for macOS

[English](README.md) · [简体中文](README.zh-CN.md)

A native macOS reimplementation of [Ditto](https://github.com/sabrogden/Ditto), the Windows clipboard manager.

**Author: 伤感咩吖** · Forked from `samgum/Ditto`

Ditto saves everything you copy to the clipboard — text, rich text, HTML, images, and files — into a searchable, persistent history you can recall and paste at any time. This project is a from-scratch Swift/AppKit port that reproduces the Windows application's feature set on macOS.

> Forked from `samgum/Ditto`. The original C/C++/MFC Windows source remains untouched; this is the parallel macOS target.

## Features

This is a feature-for-feature port of the Windows Ditto clipboard manager:

- **Menu-bar application** with global activation hot key (configurable)
- **Multi-format capture**: plain text, RTF, HTML, PNG images, and file drop lists
- **Local-first storage**: SQLite database under `~/Library/Application Support/Ditto/Ditto.db` — no cloud, no telemetry
- **History window** with multi-select, search, type filters, and group filters
- **Search modes**: contains, wildcard (`*`/`?`), and regular expression, with targets (description / quick-paste text / full text) and inline `/q` and `/f` prefixes
- **Special paste transforms**: plain text, UPPERCASE, lowercase, Title Case, Sentence case, camelCase, invert case, remove/add line feeds, typoglycemia, trim whitespace, POSIX-ify paths, ASCII-only, slugify, append date/time, generate GUID, paste as image
- **Groups** (folders) with nesting, create / rename / delete
- **Favorites & pinned clips** (never auto-delete) that survive trimming and sort to the top
- **Copy buffers** — 5 independent numbered slots with per-slot copy/paste global hot keys
- **First-ten paste hot keys** — paste the Nth visible clip with ⌘1–⌘0
- **Per-clip quick-paste text and shortcut keys**
- **Multi-paste** — concatenate several clips with a configurable separator (`[LF]`, `[TAB]`, …), reverse order, optionally save as a new clip
- **Themes** — system / light / dark, plus a configurable accent colour
- **Statistics** — session and all-time copy/paste counts
- **LAN sync** — send and receive clips between machines over TCP (port 23443, configurable) with **AES-256-GCM** encryption; "friends" list with per-peer "send all"
- **QR code** generation from any text clip
- **Clip properties** and **clip editor** windows
- **Clip compare** — side-by-side diff or launch an external diff tool
- **Image viewer** for image clips with thumbnails in the list
- **Colour-code detection** — clips that are hex colours draw a colour swatch
- **Import / export** a self-contained macOS history archive (SQLite)
- **Import Windows Ditto databases** (`Ditto.db`) and Ditto SQLite exports, with zlib decompression and Win32 format mapping (`CF_UNICODETEXT`, `CF_TEXT`, `Rich Text Format`, `HTML Format`, `PNG`, `CF_DIB`, `CF_HDROP`)
- **Exclude / include apps** from capture
- **Expiry** — auto-remove clips older than N days (pinned clips are preserved)
- **Max clip size** limit
- **Login auto-start** via a user LaunchAgent with `KeepAlive` crash recovery
- **Paste simulation** into the previously-focused application (⌘V) — requires Accessibility permission
- **Localization** in 10+ languages

## Build

```bash
swift build -c release
```

Requires Swift 5.9+ and macOS 13+. The package links the system `sqlite3` and `zlib`.

## Run

```bash
swift run DittoMac
```

## Package

```bash
bash scripts/package-dmg.sh
```

Produces `dist/Ditto-macOS.dmg` containing `Ditto.app` and an `/Applications` shortcut.

## Permissions

macOS requires granting Ditto **Accessibility** permission (System Settings ▸ Privacy & Security ▸ Accessibility) so it can simulate the paste keystroke. Network sync may prompt for **Local Network** permission.

## Architecture

```
Sources/DittoMac/
├── App/            AppDelegate, entry point
├── Models/         ClipboardEntry, settings, hot keys, theme, friend
├── Storage/        SQLite database, clipboard store, Windows DB importer
├── Clipboard/      pasteboard monitor, paste simulator
├── Text/           special-paste transforms, slugify transliteration
├── Features/       QR codes, copy buffers, statistics, search, color detection, diff
├── HotKey/         Carbon global hot-key controller
├── System/         login agent, active-app tracker
├── Sync/           AES-256 encryption, LAN sync coordinator
├── Localization/   language packs + manager
└── UI/             history, preferences, properties, editor, groups, friends, …
```

## License

GPL-3.0, inherited from the upstream Ditto project.

---

> Author: **伤感咩吖** · This is an independent macOS port maintained in this repository. The original Windows Ditto is © its respective authors under GPL-3.0.
