# Changelog — Ditto for macOS

Author: **伤感咩吖** · A native Swift/AppKit port of [Ditto](https://github.com/sabrogden/Ditto).

## Replication status

A headless `--selftest` exercises the pure-logic subsystems (39 assertions). A
multi-agent audit compared the macOS port against the Windows source across 12
feature areas; the critical gaps it surfaced have been addressed:

### Clipboard capture & formats
- Plain text, RTF, HTML, PNG, TIFF→PNG, file drop lists (multi-format per clip)
- Back-to-back + global duplicate suppression, CRC32 checksum (Windows `CRC` column)
- Exclude/include apps; honours `Clipboard Viewer Ignore` /
  `ExcludeClipboardContentFromMonitorProcessing` / transient/concealed pasteboard types
- Source-app tracking, single-instance guard

### Special paste transforms (OleClipSource parity)
- Mutually-exclusive dispatch (else-if, first match wins)
- UPPERCASE / lowercase / Title / Sentence / camelCase / invert case
- Remove / one / two line feeds; trim; ASCII-only; POSIX-ify paths
- Slugify with full transliteration map (Latin/Greek/Cyrillic/currency/symbols)
- Typoglycemia (real RNG, trailing-punctuation handling — matches Windows)
- Append date/time, generate GUID
- Paste-as-image (text-as-file-path semantics, with text-render fallback)
- Multi-image paste: composite selected images horizontally / vertically

### Database & persistence
- SQLite with `ClipboardEntries`, `Groups`, `ClipBlobs`, `CopyBuffers`, `Friends`
- Schema versioning + `ALTER TABLE` migration (v1→v3)
- Windows Ditto DB import (Main/Data tables, zlib `lOriginalSize` decompression,
  CF_UNICODETEXT/CF_TEXT/RTF/HTML/PNG/CF_DIB/CF_HDROP mapping)
- Self-contained macOS history export/import archive

### Search
- Contains / wildcard (`*` `?`) / regex modes
- Targets: description / quick-paste text / full text (RTF+HTML extraction)
- Inline `/q` (quick-paste) and `/f` (full-text) prefixes
- Alt+C cancel filter, Up-arrow recall last search, find-as-you-type

### Groups
- Nested groups (unlimited via parentId), hierarchical filter display
- Create / rename / delete with re-parenting of children & clips

### Hot keys & paste
- Main activation hot key (configurable, with presets + free-form)
- Per-clip GLOBAL paste hot keys (`lShortCut` + `globalShortCut`)
- Global first-ten paste hot keys (positions 1–10)
- Copy-buffer copy/paste hot keys (5 slots)
- Move-to-group hot key storage (`moveToGroupShortcut`)
- Paste simulation (⌘V) into the previously-focused app; move-to-top-on-paste

### History window (QPasteWnd parity)
- Multi-select, type & group filters, count badge
- Thumbnail drawing, colour-code swatch, pinned/favorite indicators, first-ten overlay
- Collapsible description/preview pane (F3)
- Always-on-top, transparency (0–40%, toggle/increase/decrease)
- Move clip up/down/top/last (Ctrl+Up/Down/Home/End)
- Context menu: special paste, groups, buffers, QR, export, web search, translate, email, compare

### Copy buffers
- 5 numbered slots, per-slot copy/paste hot keys, persistent CopyBuffers table

### Themes
- System / light / dark + configurable accent colour (persists via secure archive)

### LAN network sync
- TCP server on port 23443, length-prefixed framing, AES-256-GCM encryption
- Friends list (name/IP/port/send-all), broadcast on copy, manual send, received-clip notification
- Local-IP discovery via `getifaddrs`

### Extras
- QR codes (CoreImage, high error-correction, configurable border)
- Statistics (session + all-time copy/paste counts)
- Clip properties (description, quick-paste, group, shortcut recorder, never-delete, formats)
- Clip editor (rich text, save / save-and-copy)
- Clip compare (side-by-side or external diff tool)
- Image viewer

### System integration
- Login auto-start LaunchAgent with `KeepAlive` crash recovery
- Active-app tracker for paste targets
- Accessibility-permission detection & prompt
- 11-language localization (en, zh-Hans, zh-Hant, ja, ko, fr, de, es, pt-BR, ru, ar) + RTL

### Tooling
- GitHub Actions CI: debug+release build, `--selftest`, DMG packaging on every push
- Bilingual README (English + 简体中文), author 伤感咩吖
