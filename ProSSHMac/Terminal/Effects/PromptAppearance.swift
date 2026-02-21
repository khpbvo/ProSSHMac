// PromptAppearance.swift
// ProSSHV2
//
// Configuration for local terminal prompt colors.
// Controls the appearance of the "username path %" prompt text
// including username style (white, single color, or rainbow),
// parent/leaf path colors, and symbol color.

import Foundation

// MARK: - UsernameStyle

/// How the username is colored in the prompt.
enum UsernameStyle: Int, CaseIterable, Identifiable, Codable, Sendable {
    case white = 0
    case singleColor = 1
    case rainbow = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .white:       return "White"
        case .singleColor: return "Single Color"
        case .rainbow:     return "Rainbow"
        }
    }
}

// MARK: - PromptAppearanceConfiguration

/// Full prompt color configuration for the local terminal.
struct PromptAppearanceConfiguration: Codable, Sendable, Equatable {

    /// Username coloring mode.
    var usernameStyle: UsernameStyle

    /// Color for the username when style is `.singleColor`.
    var usernameColor: GradientColor

    /// Six cycling colors for rainbow mode.
    var rainbowColors: [GradientColor]

    /// Color for the path portion (e.g., `~`).
    var pathColor: GradientColor

    /// Color for the current folder (last path segment).
    var currentFolderColor: GradientColor

    /// Color for the trailing symbol (`%` for zsh, `$` for bash).
    var symbolColor: GradientColor

    // MARK: - Defaults

    static let `default` = PromptAppearanceConfiguration(
        usernameStyle: .rainbow,
        usernameColor: GradientColor(red: 0.4, green: 0.8, blue: 1.0),
        rainbowColors: [
            GradientColor(red: 1.0, green: 0.0, blue: 0.0),     // red
            GradientColor(red: 1.0, green: 0.5, blue: 0.0),     // orange
            GradientColor(red: 1.0, green: 1.0, blue: 0.0),     // yellow
            GradientColor(red: 0.0, green: 1.0, blue: 0.0),     // green
            GradientColor(red: 0.0, green: 0.8, blue: 1.0),     // cyan
            GradientColor(red: 0.6, green: 0.2, blue: 1.0)      // violet
        ],
        // Royal purple for parent path components (e.g. ~/Desktop/)
        pathColor: GradientColor(red: 0.4706, green: 0.3176, blue: 0.6627),
        // Orange for the active/current folder segment
        currentFolderColor: GradientColor(red: 1.0, green: 0.55, blue: 0.0),
        symbolColor: GradientColor(red: 0.58, green: 0.58, blue: 0.58) // gray (≈256-color 245)
    )

    enum CodingKeys: String, CodingKey {
        case usernameStyle
        case usernameColor
        case rainbowColors
        case pathColor
        case currentFolderColor
        case symbolColor
    }

    init(
        usernameStyle: UsernameStyle,
        usernameColor: GradientColor,
        rainbowColors: [GradientColor],
        pathColor: GradientColor,
        currentFolderColor: GradientColor,
        symbolColor: GradientColor
    ) {
        self.usernameStyle = usernameStyle
        self.usernameColor = usernameColor
        self.rainbowColors = rainbowColors
        self.pathColor = pathColor
        self.currentFolderColor = currentFolderColor
        self.symbolColor = symbolColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        usernameStyle = try container.decodeIfPresent(UsernameStyle.self, forKey: .usernameStyle) ?? d.usernameStyle
        usernameColor = try container.decodeIfPresent(GradientColor.self, forKey: .usernameColor) ?? d.usernameColor
        rainbowColors = try container.decodeIfPresent([GradientColor].self, forKey: .rainbowColors) ?? d.rainbowColors
        pathColor = try container.decodeIfPresent(GradientColor.self, forKey: .pathColor) ?? d.pathColor
        currentFolderColor = try container.decodeIfPresent(GradientColor.self, forKey: .currentFolderColor) ?? d.currentFolderColor
        symbolColor = try container.decodeIfPresent(GradientColor.self, forKey: .symbolColor) ?? d.symbolColor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usernameStyle, forKey: .usernameStyle)
        try container.encode(usernameColor, forKey: .usernameColor)
        try container.encode(rainbowColors, forKey: .rainbowColors)
        try container.encode(pathColor, forKey: .pathColor)
        try container.encode(currentFolderColor, forKey: .currentFolderColor)
        try container.encode(symbolColor, forKey: .symbolColor)
    }

    // MARK: - Persistence

    static let defaultsKey = "terminal.prompt.appearance"

    static func load(from defaults: UserDefaults = .standard) -> PromptAppearanceConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(PromptAppearanceConfiguration.self, from: data)
        else {
            return .default
        }
        return config
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Shell Prompt Generation

    /// Build the zsh PROMPT string based on the current configuration.
    func zshPrompt(user: String) -> String {
        let usernameStr: String
        switch usernameStyle {
        case .white:
            usernameStr = "%F{255}\(user)%f"
        case .singleColor:
            let (r, g, b) = usernameColor.rgb255
            usernameStr = "%{\u{1b}[38;2;\(r);\(g);\(b)m%}\(user)%{\u{1b}[0m%}"
        case .rainbow:
            var parts = [String]()
            if !rainbowColors.isEmpty {
                for (i, char) in user.enumerated() {
                    let c = rainbowColors[i % rainbowColors.count]
                    let (r, g, b) = c.rgb255
                    parts.append("%{\u{1b}[38;2;\(r);\(g);\(b)m%}\(char)")
                }
                usernameStr = parts.joined() + "%{\u{1b}[0m%}"
            } else {
                usernameStr = "%F{255}\(user)%f"
            }
        }

        let pathStr = "$(prossh_prompt_path)"

        let (sr, sg, sb) = symbolColor.rgb255
        let symbolStr = "%{\u{1b}[38;2;\(sr);\(sg);\(sb)m%}%%%{\u{1b}[0m%}"

        return "\(usernameStr) \(pathStr) \(symbolStr) "
    }

    /// Build the bash PS1 string based on the current configuration.
    func bashPrompt(user: String) -> String {
        let usernameStr: String
        switch usernameStyle {
        case .white:
            usernameStr = "\\[\\e[38;2;255;255;255m\\]\(user)\\[\\e[0m\\]"
        case .singleColor:
            let (r, g, b) = usernameColor.rgb255
            usernameStr = "\\[\\e[38;2;\(r);\(g);\(b)m\\]\(user)\\[\\e[0m\\]"
        case .rainbow:
            var parts = [String]()
            if !rainbowColors.isEmpty {
                for (i, char) in user.enumerated() {
                    let c = rainbowColors[i % rainbowColors.count]
                    let (r, g, b) = c.rgb255
                    parts.append("\\[\\e[38;2;\(r);\(g);\(b)m\\]\(char)")
                }
                usernameStr = parts.joined() + "\\[\\e[0m\\]"
            } else {
                usernameStr = "\\[\\e[38;2;255;255;255m\\]\(user)\\[\\e[0m\\]"
            }
        }

        let pathStr = "$(prossh_prompt_path)"

        let (sr, sg, sb) = symbolColor.rgb255
        let symbolStr = "\\[\\e[38;2;\(sr);\(sg);\(sb)m\\]$\\[\\e[0m\\]"

        return "\(usernameStr) \(pathStr) \(symbolStr) "
    }

    /// zsh helper function to color parent path and current folder separately.
    func zshPathFunction() -> String {
        let (pr, pg, pb) = pathColor.rgb255
        let (lr, lg, lb) = currentFolderColor.rgb255

        let parentStart = "%{\\e[38;2;\(pr);\(pg);\(pb)m%}"
        let leafStart = "%{\\e[38;2;\(lr);\(lg);\(lb)m%}"
        let reset = "%{\\e[0m%}"

        return """
prossh_prompt_path() {
  local p="${PWD/#$HOME/~}"
  if [[ "$p" == "/" || "$p" == "~" || "$p" != */* ]]; then
    print -n "\(leafStart)$p\(reset)"
    return
  fi
  local parent="${p%/*}"
  local leaf="${p##*/}"
  if [[ -z "$parent" ]]; then
    parent="/"
  fi
  print -n "\(parentStart)$parent/\(reset)\(leafStart)$leaf\(reset)"
}
"""
    }

    /// bash helper function to color parent path and current folder separately.
    func bashPathFunction() -> String {
        let (pr, pg, pb) = pathColor.rgb255
        let (lr, lg, lb) = currentFolderColor.rgb255

        return """
prossh_prompt_path() {
  local p="${PWD/#$HOME/~}"
  if [[ "$p" == "/" || "$p" == "~" || "$p" != */* ]]; then
    printf "\\[\\e[38;2;\(lr);\(lg);\(lb)m\\]%s\\[\\e[0m\\]" "$p"
    return
  fi
  local parent="${p%/*}"
  local leaf="${p##*/}"
  if [[ -z "$parent" ]]; then
    parent="/"
  fi
  printf "\\[\\e[38;2;\(pr);\(pg);\(pb)m\\]%s/\\[\\e[0m\\]\\[\\e[38;2;\(lr);\(lg);\(lb)m\\]%s\\[\\e[0m\\]" "$parent" "$leaf"
}
"""
    }
}

// MARK: - GradientColor RGB255 Helper

extension GradientColor {
    /// Returns (R, G, B) as 0–255 integers for ANSI true-color escape sequences.
    var rgb255: (Int, Int, Int) {
        (
            Int((red.clamped(to: 0...1) * 255).rounded()),
            Int((green.clamped(to: 0...1) * 255).rounded()),
            Int((blue.clamped(to: 0...1) * 255).rounded())
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
