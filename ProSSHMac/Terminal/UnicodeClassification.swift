// UnicodeClassification.swift
// ProSSHV2
//
// Shared Unicode range classification helpers used by parser/renderer/font paths.

import Foundation

nonisolated enum UnicodeClassification {
    private static let emojiRanges: [ClosedRange<UInt32>] = [
        0x231A...0x231B,
        0x23E9...0x23F3,
        0x23F8...0x23FA,
        0x2460...0x24FF,
        0x2600...0x26FF,
        0x2700...0x27BF,
        0xFE00...0xFE0F,
        0x1F1E0...0x1F1FF,
        0x1F300...0x1F6FF,
        0x1F700...0x1F77F,
        0x1F900...0x1FAFF,
        0xE0020...0xE007F,
    ]

    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x2E80...0x2FDF,
        0x3000...0x303F,
        0x3040...0x309F,
        0x30A0...0x30FF,
        0x3100...0x312F,
        0x31A0...0x31BF,
        0x3200...0x33FF,
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xAC00...0xD7AF,
        0xF900...0xFAFF,
        0xFF01...0xFF60,
        0xFFE0...0xFFE6,
        0x20000...0x2A6DF,
        0x2A700...0x2FA1F,
    ]

    private static let powerlineRanges: [ClosedRange<UInt32>] = [
        0x2800...0x28FF,
        0xE000...0xE00A,
        0xE0A0...0xE0A7,
        0xE0B0...0xE0D4,
        0xE200...0xE2A9,
        0xE5FA...0xE6AC,
        0xE700...0xE7C5,
        0xF000...0xF2E0,
        0xF500...0xFD46,
        0xF0001...0xF1AF0,
    ]

    static func isEmojiCodepoint(_ value: UInt32) -> Bool {
        if value == 0x200D || value == 0x20E3 || value == 0x00A9 || value == 0x00AE || value == 0x2122 {
            return true
        }
        return contains(value, in: emojiRanges)
    }

    static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        isEmojiCodepoint(scalar.value)
    }

    static func isCJKCodepoint(_ value: UInt32) -> Bool {
        contains(value, in: cjkRanges)
    }

    static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        isCJKCodepoint(scalar.value)
    }

    static func isPowerlineCodepoint(_ value: UInt32) -> Bool {
        contains(value, in: powerlineRanges)
    }

    static func isPowerlineScalar(_ scalar: Unicode.Scalar) -> Bool {
        isPowerlineCodepoint(scalar.value)
    }

    private static func contains(_ value: UInt32, in ranges: [ClosedRange<UInt32>]) -> Bool {
        var low = 0
        var high = ranges.count - 1

        while low <= high {
            let mid = (low + high) >> 1
            let range = ranges[mid]
            if value < range.lowerBound {
                high = mid - 1
            } else if value > range.upperBound {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }
}
