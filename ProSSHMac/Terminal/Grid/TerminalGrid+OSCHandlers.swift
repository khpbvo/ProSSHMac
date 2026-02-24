// Extracted from TerminalGrid.swift

import Foundation

extension TerminalGrid {

    // MARK: - Window Title (OSC 0/1/2)

    /// Set the window title (OSC 0/2).
    nonisolated func setWindowTitle(_ title: String) {
        windowTitle = title
    }

    /// Set the icon name (OSC 1).
    nonisolated func setIconName(_ name: String) {
        iconName = name
    }

    /// Set the current working directory (OSC 7).
    nonisolated func setWorkingDirectory(_ path: String) {
        workingDirectory = path
    }

    /// Set the current hyperlink URI (OSC 8).
    /// Pass nil to end the current hyperlink.
    nonisolated func setCurrentHyperlink(_ uri: String?) {
        currentHyperlink = uri
    }

    // MARK: - Color Palette (OSC 4/10/11/12)

    /// Set a custom palette color at a given index (OSC 4).
    nonisolated func setPaletteColor(index: UInt8, r: UInt8, g: UInt8, b: UInt8) {
        customPalette[index] = (r, g, b)
        markAllDirty()
    }

    /// Get the current RGB for a palette index (custom or default).
    nonisolated func paletteColor(index: UInt8) -> (UInt8, UInt8, UInt8) {
        if let custom = customPalette[index] {
            return custom
        }
        let rgb = ColorPalette.rgb(forIndex: index)
        return (rgb.r, rgb.g, rgb.b)
    }

    /// Reset a palette color to its default (OSC 104).
    nonisolated func resetPaletteColor(index: UInt8) {
        customPalette.removeValue(forKey: index)
        markAllDirty()
    }

    /// Set the cursor color (OSC 12).
    nonisolated func setCursorColor(r: UInt8, g: UInt8, b: UInt8) {
        cursorColor = (r, g, b)
    }

    /// Set the default foreground color (OSC 10).
    nonisolated func setDefaultForegroundRGB(r: UInt8, g: UInt8, b: UInt8) {
        defaultForegroundColor = (r, g, b)
        markAllDirty()
    }

    /// Set the default background color (OSC 11).
    nonisolated func setDefaultBackgroundRGB(r: UInt8, g: UInt8, b: UInt8) {
        defaultBackgroundColor = (r, g, b)
        markAllDirty()
    }

    /// Reset the cursor color to default (OSC 112).
    nonisolated func resetCursorColor() {
        cursorColor = nil
    }

    /// Get the default foreground color RGB.
    nonisolated func defaultForegroundRGB() -> (UInt8, UInt8, UInt8) {
        defaultForegroundColor
    }

    /// Get the default background color RGB.
    nonisolated func defaultBackgroundRGB() -> (UInt8, UInt8, UInt8) {
        defaultBackgroundColor
    }

}
