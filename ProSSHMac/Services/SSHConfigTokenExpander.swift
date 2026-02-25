// Extracted from SSHConfigParser.swift
import Foundation

// MARK: - Token Expansion

/// Expands SSH config `%`-tokens (e.g. `%h`, `%u`, `%p`) in directive values.
struct SSHConfigTokenExpander: Sendable {

    struct Context: Sendable {
        let hostname: String
        let username: String
        let port: UInt16
        let localHostname: String
        let homeDirectory: String

        /// Build context from an SSHConfigEntry (resolving hostname/user/port with fallbacks).
        init(
            hostname: String,
            username: String,
            port: UInt16 = 22,
            localHostname: String = ProcessInfo.processInfo.hostName,
            homeDirectory: String = NSHomeDirectory()
        ) {
            self.hostname = hostname
            self.username = username
            self.port = port
            self.localHostname = localHostname
            self.homeDirectory = homeDirectory
        }
    }

    func expand(_ value: String, context: Context) -> String {
        var result = ""
        var iterator = value.makeIterator()

        while let char = iterator.next() {
            if char == "%" {
                guard let token = iterator.next() else {
                    result.append(char)
                    break
                }
                switch token {
                case "h", "n": result += context.hostname
                case "u", "r": result += context.username
                case "p":      result += String(context.port)
                case "l":      result += context.localHostname.components(separatedBy: ".").first ?? context.localHostname
                case "L":      result += context.localHostname
                case "d":      result += context.homeDirectory
                case "%":      result += "%"
                default:       result += "%" + String(token)  // Preserve unknown tokens
                }
            } else {
                result.append(char)
            }
        }

        return result
    }
}
