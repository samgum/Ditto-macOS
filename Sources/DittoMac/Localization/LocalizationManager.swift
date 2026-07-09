import Foundation

/// JSON-backed string table loaded from the bundled `Localizations/*.json`
/// packs. Mirrors the Windows `MultiLanguage` plugin but uses simple
/// key/value JSON instead of compiled string tables.
final class LocalizationManager {
    static let shared = LocalizationManager()

    private let languageKey = "Ditto.Language"
    private var strings: [String: String] = [:]

    var currentLanguage: String {
        UserDefaults.standard.string(forKey: languageKey) ?? "en"
    }

    let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("pt-BR", "Português (Brasil)"),
        ("ru", "Русский"),
        ("ar", "العربية")
    ]

    /// Right-to-left languages get a flipped user interface direction.
    var isRTL: Bool { currentLanguage == "ar" }

    private init() {
        loadLanguage(currentLanguage)
    }

    func setLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: languageKey)
        loadLanguage(code)
        NotificationCenter.default.post(name: .dittoLanguageChanged, object: nil)
    }

    func text(_ key: String) -> String {
        strings[key] ?? Self.fallbackStrings[key] ?? key
    }

    private func loadLanguage(_ code: String) {
        for bundle in candidateBundles() {
            if let url = bundle.url(forResource: code, withExtension: "json", subdirectory: "Localizations")
                ?? bundle.url(forResource: code, withExtension: "json") {
                if let data = try? Data(contentsOf: url),
                   let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                    strings = decoded
                    return
                }
            }
        }
        strings = Self.fallbackStrings
    }

    private func candidateBundles() -> [Bundle] {
        var bundles: [Bundle] = [Bundle.module]
        if let module = Bundle(url: Bundle.main.bundleURL) { bundles.append(module) }
        bundles.append(Bundle.main)
        return bundles
    }

    private static let fallbackStrings: [String: String] = [
        "app_name": "Ditto",
        "show_history": "Show History",
        "preferences": "Preferences…",
        "import_history": "Import History…",
        "import_windows_database": "Import Windows Ditto Database…",
        "export_history": "Export History…",
        "quit": "Quit Ditto",
        "search": "Search",
        "clip": "Clip",
        "type": "Type",
        "all_types": "All Types",
        "text_clips": "Text",
        "image_clips": "Images",
        "file_clips": "Files",
        "pdf_clips": "PDF Documents",
        "rich_text_clips": "RTF",
        "html_clips": "HTML",
        "date": "Date",
        "copy": "Copy",
        "paste": "Paste",
        "delete": "Delete",
        "favorite": "Favorite",
        "favorites": "Favorites",
        "group": "Group",
        "all_groups": "All",
        "ungrouped": "Ungrouped",
        "set_group": "Set Group…",
        "move_to_group": "Move to Group…",
        "new_group": "New Group",
        "group_name": "Group name",
        "clear": "Clear",
        "language": "Language",
        "hot_key": "Hot Key",
        "record_hot_key": "Record…",
        "max_history": "Max History",
        "close": "Close",
        "disabled": "Disabled",
        "import_success": "History imported.",
        "import_windows_success": "Windows Ditto database imported.",
        "export_success": "History exported.",
        "operation_failed": "Operation failed.",
        "statistics": "Statistics",
        "search_clips": "Search clips",
        "theme": "Theme",
        "general": "General",
        "appearance": "Appearance",
        "network": "Network",
        "advanced": "Advanced",
        "copy_buffers": "Copy Buffers",
        "friends": "Friends",
        "save": "Save",
        "cancel": "Cancel",
        "ok": "OK",
        "edit_clip": "Edit Clip",
        "clip_properties": "Clip Properties",
        "qr_code": "QR Code",
        "properties": "Properties",
        "send_to_friend": "Send to Friend",
        "special_paste": "Special Paste",
        "uppercase": "UPPERCASE",
        "lowercase": "lowercase",
        "capitalize": "Capitalize Words",
        "sentence_case": "Sentence case",
        "camel_case": "camelCase",
        "invert_case": "Invert Case",
        "remove_line_feeds": "Remove Line Feeds",
        "add_one_line_feed": "Add One Line Feed",
        "add_two_line_feeds": "Add Two Line Feeds",
        "typoglycemia": "Typoglycemia",
        "trim_whitespace": "Trim Whitespace",
        "paste_as_plain_text": "Paste as Plain Text",
        "posixify_paths": "Posixify Paths",
        "ascii_only": "ASCII Text Only",
        "slugify": "Slugify",
        "append_date_time": "Append Date/Time",
        "generate_guid": "Generate GUID",
        "export_text_file": "Export to Text File…",
        "export_image_file": "Export to Image File…",
        "export_pdf_file": "Export to PDF File…",
        "web_search": "Search the Web",
        "translate": "Translate",
        "email_clip": "Email Clip",
        "share": "Share",
        "never_auto_delete": "Never Auto Delete",
        "pinned": "Pinned",
        "pasted": "Pasted",
        "copies": "Copies",
        "pastes": "Pastes",
        "trip": "This Session",
        "total": "All Time",
        "reset_stats": "Reset",
        "no_clips": "No clips yet. Copy something!",
        "history_empty_message": "Your clipboard history will appear here.",
        "no_matching_clips": "No matching clips.",
        "clips_count_format": "Showing %d of %d clips",
        "confirm_clear": "Clear all clipboard history?",
        "confirm_delete": "Delete the selected clip?",
        "record_shortcut": "Press a key combination",
        "empty": "Empty",
        "open_at_login": "Open at Login",
        "search_mode": "Search Mode",
        "contains": "Contains",
        "wildcard": "Wildcard",
        "regex": "Regex",
        "search_in": "Search In",
        "description": "Description",
        "full_text": "Full Text",
        "exclude_apps": "Excluded Apps",
        "include_apps": "Included Apps",
        "separator": "Separator",
        "multi_paste": "Multi-Paste",
        "paste_multiple": "Paste Selected",
        "multi_paste_reverse": "Multi-Paste: reverse order",
        "multi_paste_save_new": "Multi-Paste: save as new clip",
        "allow_duplicate_clips": "Allow duplicate clips",
        "regex_case_insensitive": "Regex case-insensitive",
        "diff_app": "Diff app",
        "play_sound_on_copy": "Play sound on copy",
        "draw_thumbnails": "Draw thumbnails",
        "font_size": "Font size",
        "lines_per_row": "Lines per row",
        "paste_as_plain_text_default": "Paste as plain text by default",
        "expire_after_days": "Expire clips after (days)",
        "enable_expiry": "Enable clip expiry",
        "max_clip_size": "Max clip size (MB, 0 = unlimited)",
        "update_time_on_paste": "Move clip to top on paste",
        "restore_clipboard_after_paste": "Restore previous clipboard after paste",
        "hide_on_paste": "Hide Ditto after paste",
        "prompt_on_delete": "Confirm before deleting",
        "show_startup_message": "Show startup message",
        "copy_buffer_slot": "Slot",
        "copy_buffer_empty": "(empty)",
        "copy_buffer_copy_hotkey": "Copy",
        "copy_buffer_paste_hotkey": "Paste",
        "sync_enabled": "Enable LAN sync",
        "sync_port": "Port",
        "sync_password": "Password",
        "sync_password_required": "Set a LAN sync password before enabling sync.",
        "sync_receive": "Allow incoming clips",
        "friend_name": "Name",
        "friend_ip": "IP Address",
        "friend_send_all": "Send all copies",
        "add_friend": "Add",
        "remove_friend": "Remove",
        "send_now": "Send Now",
        "clip_received": "Clip received from",
        "theme_system": "Match System",
        "theme_light": "Light",
        "theme_dark": "Dark",
        "accent_color": "Accent Color",
        "about": "About Ditto",
        "version": "Version",
        "about_body": "Ditto for macOS\nVersion %@\n\nAuthor: 伤感咩吖\nA native macOS port of the Ditto clipboard manager.\nhttps://github.com/samgum/Ditto-macOS",
        "new_clip": "New Clip",
        "move_up": "Move Up",
        "move_down": "Move Down",
        "move_top": "Move to Top",
        "move_last": "Move to Last",
        "always_on_top": "Always on Top",
        "transparency": "Transparency",
        "description_pane": "Description Pane",
        "show_first_ten": "Show first-ten index",
        "positioning": "Window Position",
        "compare_clips": "Compare Clips",
        "select_left": "Select as Left",
        "select_right": "Select as Right & Compare",
        "quick_paste_text": "Quick Paste Text",
        "shortcut_key": "Shortcut Key",
        "global": "Global",
        "last_pasted": "Last pasted",
        "source_app": "Source App",
        "never": "never",
        "capture_into_buffer": "Capture current clipboard into…",
        "accessibility_required_title": "Grant Accessibility to paste",
        "accessibility_required_body": "Ditto simulates ⌘V to paste into other apps, which macOS only allows if Ditto is enabled in System Settings ▸ Privacy & Security ▸ Accessibility. The clip is already copied — press ⌘V yourself for now, then grant the permission so Ditto can paste automatically.",
        "open_system_settings": "Open System Settings",
        "show_save_notification": "Show a notification when a clip is saved",
        "show_save_animation": "Show save animation",
        "database": "Database",
        "backup_database": "Backup Database…",
        "compact_database": "Compact Database",
        "compact_done": "Database compacted.",
        "regex_filters": "Skip clips matching (regex, one per line)",
        "delete_unused": "Delete Never-Pasted Clips",
        "confirm_delete_unused": "Delete all clips that have never been pasted?",
        "pin_to_top": "Pin to Top",
        "remove_pin": "Unpin",
        "database_location": "Database Location",
        "restart_needed": "Restart Ditto to apply the new database location.",
        "check_for_updates": "Check for updates on launch",
        "groups": "Groups",
        "new_subgroup": "New Subgroup",
        "choose": "Choose…",
        "unlimited": "Unlimited",
        "custom": "Custom…",
        "plain_text": "Plain Text",
        "rich_text_format": "Rich Text Format",
        "html_format": "HTML Format",
        "png_format": "PNG",
        "pdf_format": "PDF",
        "files_count_format": "Files (%d)",
        "update_available_format": "Ditto %@ is available",
        "update_message_format": "You have %@. Download from GitHub Releases.",
        "download": "Download",
        "later": "Later",
        "startup_message_format": "Ditto is running in the menu bar. %@: %@\n\nTo enable paste, grant Accessibility permission in System Settings ▸ Privacy & Security.",
        "accessibility_granted": "Accessibility enabled",
        "grant_accessibility": "Grant Accessibility…",
        "backup_success": "Database backup created."
    ]
}

extension Notification.Name {
    static let dittoLanguageChanged = Notification.Name("DittoLanguageChanged")
    static let dittoThemeChanged = Notification.Name("DittoThemeChanged")
    static let dittoSettingsChanged = Notification.Name("DittoSettingsChanged")
    static let dittoClipReceived = Notification.Name("DittoClipReceived")
}
