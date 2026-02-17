import Foundation
import SwiftUI
import AppKit

enum PlatformClipboard {
    static func readString() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }

    @discardableResult
    static func writeString(_ value: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }
}

enum PlatformDevice {
    static var isPad: Bool {
        return false
    }
}

enum PlatformURL {
    @MainActor
    static func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

extension View {
    func iosAutocapitalizationWords() -> some View {
        return self
    }

    func iosAutocapitalizationNever() -> some View {
        return self
    }

    func iosKeyboardNumberPad() -> some View {
        return self
    }

    func iosInlineNavigationBarTitleDisplayMode() -> some View {
        return self
    }
}
