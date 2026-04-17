import Foundation

/// Static, per-app hints appended to the LLM's system prompt so the model
/// knows what *kind* of text it's processing even before reading any
/// ambient context. Deliberately short so token cost stays tiny.
enum AppProfiles {

    /// Apps whose on-screen content we refuse to read (ambient capture off)
    /// and whose app-profile hint we also skip. Keyed by bundle identifier.
    /// Users can extend this list in code if needed.
    static let sensitiveBundleIds: Set<String> = [
        // Password managers
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword4",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
        // System security surfaces
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.apple.Preferences",
        // Ourselves — don't feed our own overlay / menu bar back into the LLM
        "com.supervibe.app",
    ]

    /// Returns true if ambient context capture should be skipped for this app.
    static func isSensitive(bundleId: String) -> Bool {
        sensitiveBundleIds.contains(bundleId)
    }

    /// Returns a short system-prompt fragment tailored to the kind of app
    /// the user is in, or nil if we have no profile for it. Caller should
    /// also honor `isSensitive` and short-circuit to nil.
    static func hint(for bundleId: String) -> String? {
        if isSensitive(bundleId: bundleId) { return nil }

        // Prefix buckets — cheap way to cover product families (JetBrains).
        for (prefix, hint) in prefixProfiles {
            if bundleId.hasPrefix(prefix) { return hint }
        }
        return exactProfiles[bundleId]
    }

    // MARK: - Tables

    private static let codeHint = "Context: user is writing code in an IDE. Preserve programming identifiers in English (camelCase, snake_case, PascalCase). Do not translate or reformat function names, API names, library names, or file paths. Keep technical punctuation like parentheses and semicolons as-is."

    private static let terminalHint = "Context: user is in a terminal. Preserve command-line syntax — flags (--verbose), paths (/usr/bin), shell operators (| && >), and English command names stay exact."

    private static let messagingHint = "Context: user is in a messaging app. Keep tone conversational and natural; short sentences are fine; informal punctuation is OK."

    private static let emailHint = "Context: user is writing a professional email. Use clean grammar, full sentences, and a courteous tone."

    private static let docsHint = "Context: user is writing a document. Use clean grammar, consistent punctuation, and a tone matching the surrounding text."

    private static let mediaHint = "Context: user is in a media or entertainment app. Treat speech as casual conversation; do NOT invent unfamiliar proper nouns, people names, or technical jargon."

    private static let prefixProfiles: [(String, String)] = [
        ("com.jetbrains.", codeHint),
    ]

    private static let exactProfiles: [String: String] = [
        // --- Code IDEs ---
        "com.apple.dt.Xcode": codeHint,
        "com.microsoft.VSCode": codeHint,
        "com.microsoft.VSCodeInsiders": codeHint,
        "com.visualstudio.code.oss": codeHint,
        "com.todesktop.230313mzl4w4u92": codeHint,  // Cursor
        "dev.zed.Zed": codeHint,
        "com.sublimetext.4": codeHint,
        "io.neovide.neovide": codeHint,
        "com.panic.Nova": codeHint,

        // --- Terminals ---
        "com.apple.Terminal": terminalHint,
        "com.googlecode.iterm2": terminalHint,
        "co.zeit.hyper": terminalHint,
        "com.github.wez.wezterm": terminalHint,
        "dev.warp.Warp-Stable": terminalHint,
        "net.kovidgoyal.kitty": terminalHint,
        "com.mitchellh.ghostty": terminalHint,
        "org.tabby.Tabby": terminalHint,

        // --- Messaging ---
        "com.tinyspeck.slackmacgap": messagingHint,
        "com.hnc.Discord": messagingHint,
        "com.whatsapp.WhatsApp": messagingHint,
        "com.apple.MobileSMS": messagingHint,
        "com.apple.iChat": messagingHint,
        "com.microsoft.teams": messagingHint,
        "com.microsoft.teams2": messagingHint,
        "org.telegram.desktop": messagingHint,
        "ru.keepcoder.Telegram": messagingHint,

        // --- Email / professional writing ---
        "com.apple.mail": emailHint,
        "com.microsoft.Outlook": emailHint,
        "com.readdle.smartemail-Mac": emailHint,

        // --- Docs / notes ---
        "com.microsoft.Word": docsHint,
        "com.microsoft.Excel": docsHint,
        "com.microsoft.Powerpoint": docsHint,
        "com.apple.iWork.Pages": docsHint,
        "com.apple.iWork.Numbers": docsHint,
        "com.apple.iWork.Keynote": docsHint,
        "notion.id": docsHint,
        "notion.Notion": docsHint,
        "md.obsidian": docsHint,
        "net.shinyfrog.bear": docsHint,
        "abnerworks.Typora": docsHint,

        // --- Media / entertainment ---
        "com.netflix.Netflix": mediaHint,
        "com.spotify.client": mediaHint,
        "com.apple.Music": mediaHint,
        "com.apple.TV": mediaHint,
        "com.apple.podcasts": mediaHint,
        "com.apple.iTunes": mediaHint,
        "tv.plex.desktop": mediaHint,
    ]
}
