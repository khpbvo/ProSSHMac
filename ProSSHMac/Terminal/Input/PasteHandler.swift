// PasteHandler.swift
// ProSSHV2
//
// Clipboard paste handling with newline normalization, optional bracketed
// paste wrapping, and payload chunking for large pastes.

import Foundation

struct PasteHandlerOptions: Sendable, Equatable {
    var chunkByteLimit: Int

    static let `default` = PasteHandlerOptions(chunkByteLimit: 4096)
}

enum PasteHandler {
    private static let bracketedPasteStart = "\u{1B}[200~"
    private static let bracketedPasteEnd = "\u{1B}[201~"

    static func readClipboardSequences(
        bracketedPasteEnabled: Bool,
        options: PasteHandlerOptions = .default
    ) -> [String] {
        sequences(
            forClipboardText: PlatformClipboard.readString(),
            bracketedPasteEnabled: bracketedPasteEnabled,
            options: options
        )
    }

    static func sequences(
        forClipboardText clipboardText: String?,
        bracketedPasteEnabled: Bool,
        options: PasteHandlerOptions = .default
    ) -> [String] {
        guard let clipboardText, !clipboardText.isEmpty else { return [] }
        return payloadChunks(
            for: clipboardText,
            bracketedPasteEnabled: bracketedPasteEnabled,
            options: options
        )
    }

    static func payload(
        for text: String,
        bracketedPasteEnabled: Bool
    ) -> String {
        let normalized = normalizeNewlines(in: text)
        guard bracketedPasteEnabled else { return normalized }
        return "\(bracketedPasteStart)\(normalized)\(bracketedPasteEnd)"
    }

    static func payloadChunks(
        for text: String,
        bracketedPasteEnabled: Bool,
        options: PasteHandlerOptions = .default
    ) -> [String] {
        let normalized = normalizeNewlines(in: text)
        guard !normalized.isEmpty else { return [] }

        let chunkLimit = max(1, options.chunkByteLimit)
        var chunks = splitByUTF8ByteLimit(normalized, maxBytes: chunkLimit)
        guard !chunks.isEmpty else { return [] }

        if bracketedPasteEnabled {
            chunks[0] = "\(bracketedPasteStart)\(chunks[0])"
            chunks[chunks.count - 1] += bracketedPasteEnd
        }

        return chunks
    }

    static func normalizeNewlines(in text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\r")
    }

    private static func splitByUTF8ByteLimit(_ text: String, maxBytes: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        guard maxBytes > 0 else { return [text] }

        var chunks: [String] = []
        var currentChunk = ""
        var currentBytes = 0

        for character in text {
            let piece = String(character)
            let pieceBytes = piece.utf8.count

            if currentBytes > 0 && currentBytes + pieceBytes > maxBytes {
                chunks.append(currentChunk)
                currentChunk = piece
                currentBytes = pieceBytes
                continue
            }

            if currentBytes == 0 && pieceBytes > maxBytes {
                chunks.append(piece)
                continue
            }

            currentChunk.append(piece)
            currentBytes += pieceBytes
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }
}
