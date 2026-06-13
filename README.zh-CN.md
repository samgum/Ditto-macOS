# Ditto for macOS（中文）

[English](README.md) · [简体中文](README.zh-CN.md)

[ Ditto ](https://github.com/sabrogden/Ditto) 剪贴板管理器的原生 macOS 重构版。

Ditto 会把你复制到剪贴板的所有内容——文本、富文本、HTML、图片、文件——保存到一个可搜索、可持久化的历史记录中，随时可以调出并粘贴。本项目是从零开始的 Swift / AppKit 移植，完整复刻了 Windows 版本的功能集。

**作者：伤感咩吖** · Fork 自 `samgum/Ditto`。原始的 C/C++/MFC Windows 源码保持不变，本仓库是与之并行的 macOS 目标。

## 功能

对 Windows 版 Ditto 剪贴板管理器的逐功能移植：

- **菜单栏应用**，带全局呼出快捷键（可配置）
- **多格式捕获**：纯文本、RTF、HTML、PNG 图片、文件拖放列表
- **本地优先存储**：SQLite 数据库位于 `~/Library/Application Support/Ditto/Ditto.db`，无云、无遥测
- **历史记录窗口**：多选、搜索、类型筛选、分组筛选
- **搜索模式**：包含、通配符（`*`/`?`）、正则表达式；可配置搜索范围（描述 / 快速粘贴文本 / 全文），并支持 `/q`、`/f` 行内前缀
- **特殊粘贴变换**：纯文本、大写、小写、首字母大写、句首大写、驼峰、反转大小写、移除/添加换行、字母打乱、去空白、路径转 POSIX、仅 ASCII、Slugify、追加日期/时间、生成 GUID、粘贴为图片
- **分组**（文件夹）支持嵌套，可创建 / 重命名 / 删除
- **收藏与置顶**（永不自动删除），不会被裁剪，并排到最前
- **复制缓冲**——5 个独立的编号槽位，每个槽位可配置复制/粘贴全局快捷键
- **前十位粘贴热键**——用 ⌘1–⌘0 粘贴第 N 个可见剪贴项
- **每个剪贴项的快速粘贴文本与快捷键**
- **多重粘贴**——用可配置分隔符（`[LF]`、`[TAB]`…）拼接多个剪贴项，可反转顺序，可选另存为新剪贴项
- **主题**——跟随系统 / 浅色 / 深色，加可配置强调色
- **统计**——本次会话与全部时间的复制/粘贴次数
- **局域网同步**——在机器间通过 TCP（端口 23443，可配置）收发剪贴项，采用 **AES-256-GCM** 加密；"好友"列表，每位好友可设"发送全部复制"
- **二维码**：从任意文本剪贴项生成
- **剪贴项属性**与**剪贴项编辑器**窗口
- **剪贴项比较**——并排差异，或启动外部差异工具
- **图片查看器**：图片剪贴项，列表中显示缩略图
- **颜色码检测**：本身是十六进制颜色的剪贴项会绘制色块
- **导入/导出**：自包含的 macOS 历史归档（SQLite）
- **导入 Windows Ditto 数据库**（`Ditto.db`）及 Ditto SQLite 导出文件，支持 zlib 解压和 Win32 格式映射（`CF_UNICODETEXT`、`CF_TEXT`、`Rich Text Format`、`HTML Format`、`PNG`、`CF_DIB`、`CF_HDROP`）
- **排除/包含应用**：可选择不捕获某些应用
- **过期**：自动移除超过 N 天的剪贴项（置顶剪贴项保留）
- **最大剪贴项大小**限制
- **登录自启**：通过用户 LaunchAgent，带 `KeepAlive` 崩溃自动重启
- **粘贴模拟**：向之前聚焦的应用发送 ⌘V（需辅助功能权限）
- **11 种语言**本地化

## 构建

```bash
swift build -c release
```

需要 Swift 5.9+ 与 macOS 13+。包链接系统的 `sqlite3` 与 `zlib`。

## 运行

```bash
swift run DittoMac
```

## 自测（无头）

```bash
swift run DittoMac --selftest
```

## 打包

```bash
bash scripts/package-dmg.sh
```

产物为 `dist/Ditto-macOS.dmg`，内含 `Ditto.app` 和一个 `/Applications` 快捷方式。

## 权限

macOS 需要在 **系统设置 ▸ 隐私与安全性 ▸ 辅助功能** 中授予 Ditto 权限，以便模拟粘贴按键。局域网同步可能会弹出**本地网络**权限请求。

## 架构

```
Sources/DittoMac/
├── App/            AppDelegate、入口、自测
├── Models/         ClipboardEntry、设置、热键、主题、Friend
├── Storage/        SQLite 数据库、剪贴板存储、Windows 数据库导入器
├── Clipboard/      剪贴板监听、粘贴模拟器
├── Text/           特殊粘贴变换、Slugify 转写表
├── Features/       二维码、复制缓冲、统计、搜索、颜色检测、差异比较
├── HotKey/         Carbon 全局热键控制器
├── System/         登录代理、活动应用追踪
├── Sync/           AES-256 加密、局域网同步协调器
├── Localization/   语言包与管理器
└── UI/             历史、偏好设置、属性、编辑器、分组、好友……
```

## 许可证

GPL-3.0，继承自上游 Ditto 项目。

---

> 作者：**伤感咩吖** · 本仓库为独立维护的 macOS 移植版。原始 Windows 版 Ditto 版权归其原作者所有，遵循 GPL-3.0。
