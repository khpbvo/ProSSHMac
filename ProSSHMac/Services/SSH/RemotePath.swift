// Extracted from LibSSHTransport.swift
import Foundation

enum RemotePath {
    nonisolated static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }
        var parts = trimmed.split(separator: "/").map(String.init)
        parts.removeAll(where: { $0.isEmpty || $0 == "." })
        let normalized = "/" + parts.joined(separator: "/")
        if normalized.count > 1 && normalized.hasSuffix("/") {
            return String(normalized.dropLast())
        }
        return normalized
    }

    nonisolated static func parent(of path: String) -> String? {
        let normalized = normalize(path)
        guard normalized != "/" else {
            return nil
        }
        guard let slash = normalized.lastIndex(of: "/") else {
            return "/"
        }
        if slash == normalized.startIndex {
            return "/"
        }
        return String(normalized[..<slash])
    }

    nonisolated static func join(_ base: String, _ name: String) -> String {
        let normalizedBase = normalize(base)
        if normalizedBase == "/" {
            return "/\(name)"
        }
        return "\(normalizedBase)/\(name)"
    }
}
