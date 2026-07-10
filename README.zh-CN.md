# Ditto for macOS（中文）

[English](README.md) · [简体中文](README.zh-CN.md)

Ditto for macOS 是一个使用 Swift / AppKit 编写的原生 macOS 剪贴板管理器，支持 macOS 13 及更新系统。它会把复制过的文本、富文本、HTML、图片、PDF 和文件列表保存为可搜索的本地历史记录，并支持查找、编辑、变换、发送和重新粘贴。

**作者：伤感咩吖**

**当前版本：1.2.1**

**许可证：GPL-3.0**

这个应用以本地优先为原则。剪贴板历史保存在本机 SQLite 数据库中，不依赖云服务，也没有遥测链路。

## 目录

- [核心亮点](#核心亮点)
- [环境要求](#环境要求)
- [构建](#构建)
- [运行](#运行)
- [打包 DMG](#打包-dmg)
- [安装与权限](#安装与权限)
- [使用方式](#使用方式)
- [偏好设置](#偏好设置)
- [局域网同步](#局域网同步)
- [导入与导出](#导入与导出)
- [数据位置](#数据位置)
- [开发说明](#开发说明)
- [架构](#架构)
- [数据库结构](#数据库结构)
- [CI](#ci)
- [已知限制](#已知限制)
- [排障](#排障)
- [许可证](#许可证)

## 核心亮点

- 菜单栏应用，支持可配置的全局呼出快捷键。
- 使用 SQLite 持久保存剪贴板历史。
- 捕获纯文本、RTF、HTML、PNG/TIFF 图片、PDF 负载和文件拖放列表。
- 更友好的历史窗口：搜索、类型筛选、分组筛选、结果计数、空状态提示、多选和拖出支持。
- 搜索模式：包含、通配符（`*` 和 `?`）、正则表达式。
- 搜索范围：描述、快速粘贴文本、从 RTF/HTML 提取的全文。
- 行内搜索前缀：`/q` 搜索快速粘贴文本，`/f` 搜索全文。
- 特殊粘贴变换：
  - 纯文本；
  - 大写；
  - 小写；
  - 单词首字母大写；
  - 句首大写；
  - 驼峰；
  - 反转大小写；
  - 移除换行；
  - 折叠为一个换行；
  - 折叠为两个换行；
  - 字母打乱；
  - 去除首尾空白；
  - POSIX 路径转换；
  - 仅 ASCII 文本；
  - slugify；
  - 追加日期/时间；
  - 生成 GUID；
  - 粘贴为图片。
- 分组支持嵌套文件夹、分组筛选、创建、重命名、删除和移动到分组。
- 收藏与置顶剪贴项，置顶剪贴项不会被自动裁剪。
- 复制缓冲：5 个独立编号槽位，每个槽位可设置复制和粘贴热键。
- 前十位粘贴热键，可快速粘贴当前可见列表的前 10 个剪贴项。
- 每个剪贴项可保存快速粘贴文本和快捷键信息。
- 多重粘贴支持自定义分隔符、反转顺序和另存为新剪贴项。
- 跟随系统、浅色、深色主题，并支持自定义强调色。
- 本次会话和累计复制/粘贴统计。
- 通过 TCP 进行局域网同步，使用 AES-256-GCM 加密，并支持好友列表。
- 可手动发送给全部好友，也可从历史窗口右键菜单发送给指定好友。
- 从文本剪贴项生成二维码。
- 剪贴项属性窗口。
- 富文本剪贴项编辑器。
- 并排差异比较。
- 可选外部差异对比工具。
- 图片查看器和列表缩略图。
- 十六进制颜色检测与色块显示。
- 按应用包含/排除捕获。
- 过期清理设置。
- 最大剪贴项大小限制。
- 通过用户 LaunchAgent 登录自启。
- 辅助功能权限检测和引导提示。
- 11 个本地化语言包：英语、简体中文、繁体中文、日语、韩语、法语、德语、西班牙语、巴西葡萄牙语、俄语和阿拉伯语。

## 环境要求

- macOS 13.0 Ventura 或更新系统。
- Swift 5.9 或更新版本。
- SwiftPM 支持的 Apple Silicon 或 Intel Mac。
- 系统 `sqlite3` 和 `zlib`；macOS 已提供。

项目不需要 Xcode 工程，直接使用 Swift Package Manager 构建。

## 构建

Debug 构建：

```bash
cd /Users/alexdavis/Ditto-macOS
swift build
```

Release 构建：

```bash
cd /Users/alexdavis/Ditto-macOS
swift build -c release
```

## 运行

从源码运行应用：

```bash
cd /Users/alexdavis/Ditto-macOS
swift run DittoMac
```

运行无头自测：

```bash
cd /Users/alexdavis/Ditto-macOS
swift run DittoMac --selftest
```

期望自测结果：

```text
68 passed, 0 failed
```

自测覆盖文本变换、slugify、颜色检测、搜索、AES 往返、局域网同步安全默认值、二维码生成、数据库持久化与 SQLite 一致性备份/迁移往返、PDF 捕获/归档/同步保真、分组重挂、复制缓冲清理、blob 生命周期清理、Windows 加密兼容辅助逻辑、Windows 导入器拒绝异常输入，以及图片粘贴路径行为。

## 打包 DMG

构建 release 应用包并生成 DMG：

```bash
cd /Users/alexdavis/Ditto-macOS
bash scripts/package-dmg.sh
```

生成产物：

```text
dist/Ditto-macOS-1.2.1.dmg
dist/Ditto-macOS.dmg
.build/stage/Ditto.app
```

打包脚本会：

- 构建 release 二进制；
- 生成 `Ditto.app`；
- 复制 `Info.plist`、图标和本地化资源；
- 对应用进行 ad-hoc 签名；
- 创建拖拽到 Applications 的 DMG 布局；
- 同时写出带版本号和不带版本号的 DMG。

## 安装与权限

### 安装

1. 打开 DMG。
2. 把 `Ditto.app` 拖入 `/Applications`。
3. 从 `/Applications` 启动 Ditto。

因为应用使用 ad-hoc 签名，macOS 可能会阻止首次启动。如果出现这种情况：

1. 打开 Finder。
2. 进入 `/Applications`。
3. 右键点击 `Ditto.app`。
4. 选择 `打开`。
5. 确认启动提示。

### 辅助功能权限

Ditto 通过模拟 `Command-V` 把内容粘贴到之前聚焦的应用中。macOS 要求这类操作必须授予辅助功能权限。

授权位置：

```text
系统设置 -> 隐私与安全性 -> 辅助功能
```

在列表中启用 `Ditto.app`。如果新构建后旧权限失效：

1. 从辅助功能列表移除旧的 Ditto 条目。
2. 重新添加 `/Applications/Ditto.app`。
3. 打开开关。
4. 重启 Ditto。

### 本地网络权限

局域网同步可能触发 macOS 本地网络权限提示。如果需要通过局域网收发剪贴项，请允许该权限。

## 使用方式

### 捕获

Ditto 运行后，像平常一样在任意应用里复制内容。捕获到的剪贴项会显示在历史窗口中。

支持捕获的内容：

- 纯文本；
- RTF；
- HTML；
- 图片；
- PDF；
- 文件列表。

Ditto 会跳过空负载、隐藏/临时剪贴板类型，以及被应用包含/排除规则或正则过滤规则拦截的内容。

### 打开历史窗口

使用菜单栏图标或配置好的全局热键打开历史窗口。

历史窗口包含：

- 搜索框；
- 搜索模式菜单；
- 类型筛选；
- 分组筛选；
- 结果计数；
- 空状态提示；
- 剪贴项表格；
- 可选预览面板；
- 工具栏动作。

### 搜索

搜索模式：

- `包含`：普通文本匹配。
- `通配符`：支持 `*` 和 `?`。
- `正则`：使用正则表达式。

搜索范围可包含：

- 描述；
- 从 RTF/HTML 提取的全文；
- 快速粘贴文本。

行内前缀：

```text
/q invoice
/f release notes
```

`/q` 搜索快速粘贴文本。`/f` 搜索提取后的全文。

### 粘贴

选中一个剪贴项后，可以把它粘贴回之前聚焦的应用。Ditto 会把剪贴项写入系统剪贴板，激活目标应用，并发送粘贴命令。

可选粘贴行为：

- 粘贴后把剪贴项移动到顶部；
- 粘贴后隐藏 Ditto；
- 粘贴后恢复之前的剪贴板；
- 默认粘贴为纯文本；
- 使用按应用配置的粘贴按键。

### 特殊粘贴

特殊粘贴会在粘贴前变换当前剪贴项。可从右键菜单和应用动作中使用。

### 多重粘贴

选中多个文本剪贴项后，可以把它们合并为一个内容粘贴。分隔符可配置，顺序可反转，也可把合并结果另存为新剪贴项。可使用 `Command-Shift-V` 或多选后的右键菜单执行粘贴。

### 分组

使用分组整理剪贴项。分组支持嵌套。删除分组时可以安全移动子分组和剪贴项，而不是直接删除整段历史。

### 复制缓冲

复制缓冲是独立于主历史记录的 5 个编号槽位。每个槽位都可以设置复制热键和粘贴热键。

### 收藏与置顶

收藏用于快速标记剪贴项。置顶剪贴项永不自动删除，并会排列到顶部。

## 偏好设置

偏好设置窗口包含以下部分：

- 通用：
  - 语言；
  - 全局呼出热键；
  - 最大历史数量；
  - 登录时打开；
  - 声音、删除确认、启动提示、更新检查；
  - 粘贴行为。
- 外观：
  - 主题；
  - 强调色；
  - 字号；
  - 每排行数；
  - 缩略图；
  - 窗口置顶；
  - 前十位序号显示。
- 搜索模式：
  - 描述搜索；
  - 全文搜索；
  - 快速粘贴文本搜索；
  - 正则忽略大小写。
- 高级：
  - 包含应用；
  - 排除应用；
  - 过期；
  - 最大剪贴项大小；
  - 重复处理；
  - 多重粘贴分隔符；
  - slugify 分隔符；
  - 差异对比工具；
  - 翻译 URL；
  - 网页搜索 URL；
  - 正则过滤；
  - 数据库位置；
  - 数据库备份与压缩。
- 复制缓冲：
  - 每个槽位的复制热键；
  - 每个槽位的粘贴热键。
- 网络：
  - 局域网同步总开关；
  - 接收剪贴项开关；
  - 端口；
  - 密码。
- 好友：
  - 好友管理说明。

高级页面支持滚动，较长的本地化文案或较小窗口不会遮挡设置项。

## 局域网同步

局域网同步使用：

- TCP 监听；
- 默认端口 `23443`；
- 长度前缀消息；
- JSON 头；
- AES-256-GCM 加密负载；
- 好友记录，包括名称、IP 地址、端口和发送全部设置。

手动发送支持：

- 发送给所有已配置好友；
- 从历史窗口右键菜单发送给某一个指定好友。

广播发送可以把新复制内容发送给标记为“发送全部”的好友。

局域网同步默认关闭，且必须设置非空同步密码才能启用。两台机器的网络密码必须一致。端口范围限制为 `1024` 至 `65535`。如果关闭接收，Ditto 仍可保留发送设置，但不会打开监听器。

## 导入与导出

### macOS 历史归档

Ditto 可以导出和导入本 macOS 移植版使用的自包含 SQLite 归档。归档会保留包括 PDF 在内的剪贴项数据与分组层级；导入到已有分组的数据库时会安全映射分组 ID。

### Windows 数据库导入

Ditto 可以导入 Windows Ditto SQLite 数据库和导出的 SQLite 数据。导入器会映射常见格式：

- `CF_UNICODETEXT`；
- `CF_TEXT`；
- `Rich Text Format`；
- `HTML Format`；
- `PNG`；
- `CF_DIB`；
- `CF_HDROP`。

当原始数据库包含分组时，Ditto 会重建可用的分组层级，并把导入的剪贴项分配到对应分组。

当源数据库记录了原始大小时，导入器会处理 zlib 压缩负载。

Windows 点对点网络协议集成与数据库导入是不同功能，目前仍有限制。

## 数据位置

默认数据库：

```text
~/Library/Application Support/Ditto/Ditto.db
```

首次启动时会自动创建数据库。可在偏好设置的“数据库位置”中选择一个文件夹，Ditto 会先将当前历史完整复制为该文件夹中的 `Ditto.db`，重启后再切换到新位置。若目标文件夹已存在 `Ditto.db`，Ditto 不会覆盖它；旧数据库也会保留，直到你确认新位置的数据完整无误。

旧 JSON 迁移来源：

```text
~/Library/Application Support/Ditto/history.json
~/Library/Application Support/Ditto/Data/
```

单实例锁：

```text
~/Library/Caches/org.ditto-cp.DittoMac.singleton.lock
```

登录项：

```text
~/Library/LaunchAgents/org.ditto-cp.DittoMac.plist
```

## 开发说明

推荐验证流程：

```bash
cd /Users/alexdavis/Ditto-macOS
swift build
swift run DittoMac --selftest
```

发布验证流程：

```bash
cd /Users/alexdavis/Ditto-macOS
swift build -c release
swift run DittoMac --selftest
bash scripts/package-dmg.sh
```

新增 UI 文案时，必须同步更新：

- `Sources/DittoMac/Localization/LocalizationManager.swift`；
- `Sources/DittoMac/Localizations/` 下的每一个 JSON 文件。

当前语言包文件：

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

线程规则：

- `ClipboardStore` 使用 `NSRecursiveLock` 保护 entries 和 groups。
- UI 读取应使用 `snapshotEntries()` 和 `snapshotGroups()`。
- 不要在主线程直接遍历 live `entries` 或 `groups` 数组。

## 架构

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
│   └── 11 个 JSON 语言包
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

## 数据库结构

主要表：

```text
ClipboardEntries
ClipBlobs
Groups
CopyBuffers
Friends
```

`ClipboardEntries` 保存剪贴项元数据：

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

`ClipBlobs` 保存较大的格式负载：

```text
blobKey TEXT PRIMARY KEY
fileExtension TEXT
data BLOB
```

`Groups` 保存嵌套分组：

```text
id INTEGER PRIMARY KEY
name TEXT
parentId INTEGER
sortOrder REAL
createdAt REAL
```

`CopyBuffers` 保存编号槽位：

```text
bufferNumber INTEGER PRIMARY KEY
entryId TEXT
```

`Friends` 保存局域网同步好友：

```text
id INTEGER PRIMARY KEY
name TEXT
ipAddress TEXT
port INTEGER
sendAll INTEGER
```

数据库迁移是幂等的。启动时会检查字段并补齐缺失列，不只依赖已存储的 schema 版本。

## CI

GitHub Actions 工作流：

```text
.github/workflows/ci.yml
```

CI 会：

1. 构建 debug。
2. 构建 release。
3. 运行 `swift run DittoMac --selftest`。
4. 在 push、tag 和手动触发时打包 DMG。
5. 上传 DMG artifact。
6. 当 ref 是 `v*` tag 时创建 release 并附带 DMG 文件。

## 已知限制

- Windows 数据库导入已实现；Windows 点对点局域网协议集成仍有限制。
- 文件剪贴项的网络文件传输尚未完整实现。
- 尚未捕获任意自定义剪贴板格式。
- 应用使用 ad-hoc 签名；首次启动和辅助功能权限可能需要手动批准。
- 一些 Windows 版偏好设置尚未暴露为 macOS UI 控件。
- 一些底层时序值目前仍在代码中固定。

## 排障

### Ditto 打开了，但没有自动粘贴

授予辅助功能权限：

```text
系统设置 -> 隐私与安全性 -> 辅助功能 -> Ditto
```

如果权限已经启用但仍无法粘贴，请从列表中移除 Ditto，重新添加 `/Applications/Ditto.app`，启用它，然后重启应用。

### 应用重复启动

Ditto 使用单实例锁：

```text
~/Library/Caches/org.ditto-cp.DittoMac.singleton.lock
```

如果存在残留进程，请退出所有 Ditto 实例后重新启动。

### 局域网同步无法接收剪贴项

检查以下设置：

1. 已启用局域网同步。
2. 已允许接收剪贴项。
3. 两台机器使用相同密码。
4. 配置端口在本地网络可访问。
5. macOS 本地网络权限已允许。
6. 好友 IP 地址和端口正确。

### 复制内容没有被保存

检查以下设置：

1. 包含/排除应用过滤。
2. 正则跳过过滤。
3. 最大剪贴项大小。
4. 过期设置。
5. 重复抑制设置。

## 许可证

Ditto for macOS 使用 GPL-3.0 分发。

作者：**伤感咩吖**
