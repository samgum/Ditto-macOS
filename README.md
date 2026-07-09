# Ditto for macOS

[English](README.md) · [简体中文](README.zh-CN.md)

Ditto for macOS is a native Swift/AppKit clipboard manager for macOS 13 and later. It keeps a searchable local history of copied text, rich text, HTML, images, PDFs, and file lists, then lets you find, edit, transform, send, and paste those clips back into the app you were using.

**Author: 伤感咩吖**

**Current version: 1.2.0**

**License: GPL-3.0**

The app is local-first. Clipboard history is stored in SQLite on your Mac, and the app does not use a cloud service or telemetry pipeline.

## Contents

- [Highlights](#highlights)
- [Requirements](#requirements)
- [Build](#build)
- [Run](#run)
- [Package a DMG](#package-a-dmg)
- [Install and Permissions](#install-and-permissions)
- [Using Ditto](#using-ditto)
- [Preferences](#preferences)
- [LAN Sync](#lan-sync)
- [Import and Export](#import-and-export)
- [Data Locations](#data-locations)
- [Development](#development)
- [Architecture](#architecture)
- [Database Schema](#database-schema)
- [CI](#ci)
- [Known Limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Highlights

- Menu-bar app with a configurable global activation hot key.
- Persistent SQLite clipboard history.
- Capture of plain text, RTF, HTML, PNG/TIFF images, PDF payloads, and file drop lists.
- Friendly history window with search, type filters, group filters, result counts, empty-state messages, multi-select, and drag-out support.
- Search modes: contains, wildcard (`*` and `?`), and regular expression.
- Search targets: description, quick-paste text, and extracted full text from RTF/HTML.
- Inline search prefixes: `/q` for quick-paste text and `/f` for full-text search.
- Special paste transformations:
  - plain text
  - UPPERCASE
  - lowercase
  - Title Case
  - Sentence case
  - camelCase
  - invert case
  - remove line feeds
  - collapse to one line feed
  - collapse to two line feeds
  - typoglycemia
  - trim whitespace
  - POSIX path conversion
  - ASCII-only text
  - slugify
  - append date/time
  - generate GUID
  - paste as image
- Groups with nested folders, group filters, create, rename, delete, and move-to-group actions.
- Favorites and pinned clips that are preserved during trimming.
- Copy buffers: 5 independent numbered clipboard slots with per-slot copy and paste hot keys.
- First-ten paste hot keys for the first 10 visible clips.
- Per-clip quick-paste text and shortcut metadata.
- Multi-paste with configurable separators, reverse order, and optional save-as-new-clip behavior.
- System, light, and dark themes with configurable accent color.
- Session and all-time statistics.
- LAN sync over TCP with AES-256-GCM encryption and a friend list.
- Manual send to all friends or to one selected friend.
- QR code generation for text clips.
- Clip properties window.
- Rich text clip editor.
- Side-by-side clip comparison.
- Optional external diff app.
- Image viewer and image thumbnails.
- Hex color detection with color swatches.
- Include/exclude app filters for capture.
- Expiry settings for old clips.
- Maximum clip size limits.
- Login auto-start through a user LaunchAgent.
- Accessibility permission detection and guided permission prompt.
- 11 localization packs: English, Simplified Chinese, Traditional Chinese, Japanese, Korean, French, German, Spanish, Brazilian Portuguese, Russian, and Arabic.

## Requirements

- macOS 13.0 Ventura or later.
- Swift 5.9 or later.
- Apple Silicon or Intel Mac supported by SwiftPM.
- System `sqlite3` and `zlib`; both are provided by macOS.

No Xcode project is required. The project builds with Swift Package Manager.

## Build

Debug build:

```bash
cd /Users/alexdavis/Ditto-macOS
swift build
```

Release build:

```bash
cd /Users/alexdavis/Ditto-macOS
swift build -c release
```

## Run

Run the app from source:

```bash
cd /Users/alexdavis/Ditto-macOS
swift run DittoMac
```

Run the headless self-test:

```bash
cd /Users/alexdavis/Ditto-macOS
swift run DittoMac --selftest
```

Expected self-test result:

```text
55 passed, 0 failed
```

The self-test covers text transforms, slugify, color detection, search, AES round trips, QR code generation, database and SQLite-consistent backup round trips, PDF capture/archive/sync preservation, group reparenting, Windows encryption compatibility helpers, Windows importer rejection behavior, and image paste-path behavior.

## Package a DMG

Build a release app bundle and DMG:

```bash
cd /Users/alexdavis/Ditto-macOS
bash scripts/package-dmg.sh
```

Generated outputs:

```text
dist/Ditto-macOS-1.2.0.dmg
dist/Ditto-macOS.dmg
.build/stage/Ditto.app
```

The packaging script:

- builds the release binary;
- stages `Ditto.app`;
- copies `Info.plist`, icon, and localization resources;
- ad-hoc signs the app;
- creates a drag-to-Applications DMG layout;
- writes both a versioned and an unversioned DMG.

## Install and Permissions

### Install

1. Open the DMG.
2. Drag `Ditto.app` into `/Applications`.
3. Start Ditto from `/Applications`.

Because the app is ad-hoc signed, macOS may block first launch. If that happens:

1. Open Finder.
2. Go to `/Applications`.
3. Right-click `Ditto.app`.
4. Choose `Open`.
5. Confirm the launch prompt.

### Accessibility Permission

Ditto simulates `Command-V` to paste into the previously focused app. macOS requires Accessibility permission for that.

Grant permission here:

```text
System Settings -> Privacy & Security -> Accessibility
```

Enable `Ditto.app` in the list. If an older permission entry stops working after a new build:

1. Remove the old Ditto entry from Accessibility.
2. Add `/Applications/Ditto.app` again.
3. Enable the toggle.
4. Restart Ditto.

### Local Network Permission

LAN sync may trigger a macOS Local Network permission prompt. Allow it if you want to receive or send clips over the local network.

## Using Ditto

### Capture

Once Ditto is running, copy normally in any app. Captured clips appear in the history window.

Supported captured content:

- plain text;
- RTF;
- HTML;
- images;
- PDFs;
- file lists.

Ditto skips empty payloads, concealed/transient pasteboard types, and content blocked by include/exclude app filters or regex filters.

### Open History

Use the menu-bar icon or the configured global hot key to show the history window.

The history window includes:

- search field;
- search mode menu;
- type filter;
- group filter;
- count label;
- empty-state message;
- table of clips;
- optional preview pane;
- toolbar actions.

### Search

Search modes:

- `Contains`: simple text matching.
- `Wildcard`: supports `*` and `?`.
- `Regex`: uses regular expressions.

Search scope settings can include:

- description;
- full text extracted from RTF/HTML;
- quick-paste text.

Inline prefixes:

```text
/q invoice
/f release notes
```

`/q` searches quick-paste text. `/f` searches extracted full text.

### Paste

Select a clip and paste it into the previously focused app. Ditto writes the selected clip to the system pasteboard, activates the target app, and sends the paste command.

Optional paste behaviors:

- move pasted clip to the top;
- hide Ditto after paste;
- restore the previous clipboard after paste;
- paste as plain text by default;
- use per-app paste key overrides.

### Special Paste

Special paste actions transform the selected clip before paste. They are available from the context menu and app actions.

### Multi-Paste

Select multiple text clips and paste them as one combined payload. The separator is configurable. The order can be reversed. The combined result can also be saved as a new clip. Use `Command-Shift-V` or the multi-selection context menu to paste the selected text clips.

### Groups

Use groups to organize clips. Groups can be nested. Deleting a group can move children and clips safely rather than deleting the entire history.

### Copy Buffers

Copy buffers are 5 numbered slots separate from the main history. Each slot can have a copy hot key and a paste hot key.

### Favorites and Pins

Favorites mark clips for quick identification. Pinned clips are never auto-deleted and sort to the top.

## Preferences

The Preferences window contains these sections:

- General:
  - language;
  - global activation hot key;
  - max history size;
  - open at login;
  - sound, delete confirmation, startup message, update checks;
  - paste behavior.
- Appearance:
  - theme;
  - accent color;
  - font size;
  - lines per row;
  - thumbnails;
  - always on top;
  - first-ten index display.
- Search Mode:
  - description search;
  - full-text search;
  - quick-paste text search;
  - regex case-insensitive mode.
- Advanced:
  - include apps;
  - exclude apps;
  - expiry;
  - max clip size;
  - duplicate handling;
  - multi-paste separator;
  - slugify separator;
  - diff app;
  - translate URL;
  - web search URL;
  - regex filters;
  - database location;
  - database backup and compaction.
- Copy Buffers:
  - per-slot copy hot key;
  - per-slot paste hot key.
- Network:
  - LAN sync master switch;
  - incoming clip switch;
  - port;
  - password.
- Friends:
  - guidance for friend management.

The Advanced page is scrollable so longer localized labels and smaller windows do not hide settings.

## LAN Sync

LAN sync uses:

- TCP listener;
- default port `23443`;
- length-prefixed messages;
- JSON headers;
- AES-256-GCM encrypted payloads;
- friend records with name, IP address, port, and send-all setting.

Manual sending supports:

- send to all configured friends;
- send to one selected friend from the history context menu.

Broadcast sending can send new copies to friends marked `send all`.

The network password must match on both machines. If receive is disabled, Ditto can still keep outbound settings without opening the listener.

## Import and Export

### macOS History Archive

Ditto can export and import a self-contained SQLite archive for this macOS port. Archives preserve clip payloads including PDF data and retain group hierarchy; imports remap group IDs safely when the destination already has groups.

### Windows Database Import

Ditto can import Windows Ditto SQLite databases and exported SQLite data. The importer maps common formats:

- `CF_UNICODETEXT`;
- `CF_TEXT`;
- `Rich Text Format`;
- `HTML Format`;
- `PNG`;
- `CF_DIB`;
- `CF_HDROP`.

The importer handles zlib-compressed payloads when the source database records an original size.

Windows peer-to-peer network protocol integration is separate from database import and is still limited.

## Data Locations

Default database:

```text
~/Library/Application Support/Ditto/Ditto.db
```

Legacy JSON migration source:

```text
~/Library/Application Support/Ditto/history.json
~/Library/Application Support/Ditto/Data/
```

Singleton lock:

```text
~/Library/Caches/org.ditto-cp.DittoMac.singleton.lock
```

Login item:

```text
~/Library/LaunchAgents/org.ditto-cp.DittoMac.plist
```

## Development

Recommended validation loop:

```bash
cd /Users/alexdavis/Ditto-macOS
swift build
swift run DittoMac --selftest
```

Release validation:

```bash
cd /Users/alexdavis/Ditto-macOS
swift build -c release
swift run DittoMac --selftest
bash scripts/package-dmg.sh
```

When adding UI strings, update all of these:

- `Sources/DittoMac/Localization/LocalizationManager.swift`;
- every JSON file under `Sources/DittoMac/Localizations/`.

Current language pack files:

```text
ar.json
de.json
en.json
es.json
fr.json
ja.json
ko.json
pt-BR.json
ru.json
zh-Hans.json
zh-Hant.json
```

Threading rule:

- `ClipboardStore` protects entries and groups with `NSRecursiveLock`.
- UI reads should use `snapshotEntries()` and `snapshotGroups()`.
- Do not iterate the live `entries` or `groups` arrays from the main thread.

## Architecture

```text
Sources/DittoMac/
├── App/
│   ├── main.swift
│   ├── AppDelegate.swift
│   ├── SelfTest.swift
│   └── SaveAnimation.swift
├── Models/
│   ├── ClipboardEntry.swift
│   ├── DittoSettings.swift
│   ├── HotKeyChoice.swift
│   ├── Theme.swift
│   └── Friend.swift
├── Storage/
│   ├── MacClipboardDatabase.swift
│   ├── ClipboardStore.swift
│   └── WindowsDittoDatabaseImporter.swift
├── Clipboard/
│   ├── ClipboardMonitor.swift
│   ├── PasteSimulator.swift
│   └── ClipboardSaveRestore.swift
├── Text/
│   ├── TextTransforms.swift
│   ├── SpecialPasteOptions.swift
│   ├── Slugify.swift
│   └── SlugifyTransliteration.swift
├── Features/
│   ├── CRC32.swift
│   ├── CopyBufferManager.swift
│   ├── Statistics.swift
│   ├── QRCodeGenerator.swift
│   ├── ColorCodeDetector.swift
│   ├── SearchEngine.swift
│   ├── ImageCompositor.swift
│   └── DiffPresenter.swift
├── HotKey/
│   └── HotKeyController.swift
├── System/
│   ├── LoginAgentManager.swift
│   └── ActiveAppTracker.swift
├── Sync/
│   ├── SyncCoordinator.swift
│   ├── AESEncryption.swift
│   ├── WindowsEncryption.swift
│   └── WindowsProtocol.swift
├── Localization/
│   └── LocalizationManager.swift
├── Localizations/
│   └── 11 JSON language packs
└── UI/
    ├── HistoryWindowController.swift
    ├── PreferencesWindowController.swift
    ├── ClipTableCellView.swift
    ├── ClipPropertiesWindowController.swift
    ├── ClipEditorWindowController.swift
    ├── GroupsWindowController.swift
    ├── FriendsWindowController.swift
    ├── QRCodeWindowController.swift
    ├── StatisticsWindowController.swift
    ├── ImageViewerWindowController.swift
    ├── SaveNotifier.swift
    ├── SaveAnimation.swift
    └── MagneticWindow.swift
```

## Database Schema

Main tables:

```text
ClipboardEntries
ClipBlobs
Groups
CopyBuffers
Friends
```

`ClipboardEntries` stores clip metadata:

```text
id TEXT PRIMARY KEY
text TEXT
rtfBlobKey TEXT
htmlBlobKey TEXT
imageBlobKey TEXT
pdfBlobKey TEXT
fileURLsJson TEXT
createdAt REAL
lastPasteDate REAL
isFavorite INTEGER
neverAutoDelete INTEGER
quickPasteText TEXT
clipOrder REAL
shortcutKey INTEGER
shortcutGlobal INTEGER
moveToGroupShortcut INTEGER
globalMoveToGroup INTEGER
crc INTEGER
sourceApp TEXT
pasteCount INTEGER
groupId INTEGER
```

`ClipBlobs` stores heavier payloads:

```text
blobKey TEXT PRIMARY KEY
fileExtension TEXT
data BLOB
```

`Groups` stores nested groups:

```text
id INTEGER PRIMARY KEY
name TEXT
parentId INTEGER
sortOrder REAL
createdAt REAL
```

`CopyBuffers` stores numbered slots:

```text
bufferNumber INTEGER PRIMARY KEY
entryId TEXT
```

`Friends` stores LAN sync peers:

```text
id INTEGER PRIMARY KEY
name TEXT
ipAddress TEXT
port INTEGER
sendAll INTEGER
```

The database migration is idempotent. Startup runs column checks and applies missing columns without relying only on a stored schema version.

## CI

GitHub Actions workflow:

```text
.github/workflows/ci.yml
```

The CI workflow:

1. Builds debug.
2. Builds release.
3. Runs `swift run DittoMac --selftest`.
4. Packages a DMG on pushes, tags, and manual dispatch.
5. Uploads the DMG artifact.
6. Creates a release with DMG files when the ref is a `v*` tag.

## Known Limitations

- Windows database import is implemented; Windows peer-to-peer LAN protocol integration is still limited.
- Network file transfer for file clips is not fully implemented.
- Arbitrary custom clipboard formats are not yet captured.
- The app is ad-hoc signed; first launch and Accessibility permission may require manual approval.
- Some preferences from the Windows app are not yet exposed as macOS UI controls.
- Some low-level timing values are currently fixed in code.

## Troubleshooting

### Ditto opens but paste does not happen

Grant Accessibility permission:

```text
System Settings -> Privacy & Security -> Accessibility -> Ditto
```

If permission is already enabled but paste still does not work, remove Ditto from the list, add `/Applications/Ditto.app` again, enable it, and restart the app.

### The app launches twice

Ditto uses a singleton lock:

```text
~/Library/Caches/org.ditto-cp.DittoMac.singleton.lock
```

If a stale process exists, quit all Ditto instances and launch again.

### LAN sync does not receive clips

Check these settings:

1. LAN sync is enabled.
2. Incoming clips are allowed.
3. Both machines use the same password.
4. The configured port is open on the local network.
5. macOS Local Network permission is allowed.
6. The friend IP address and port are correct.

### A copied item is not saved

Check these settings:

1. Include/exclude app filters.
2. Regex skip filters.
3. Maximum clip size.
4. Expiry settings.
5. Duplicate suppression settings.

## License

Ditto for macOS is distributed under GPL-3.0.

Author: **伤感咩吖**
