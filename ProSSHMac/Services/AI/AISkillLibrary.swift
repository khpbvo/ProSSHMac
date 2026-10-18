import Foundation
import os.log

/// A playbook the copilot loads on demand (`load_skill`): a Markdown file with front matter.
/// See Docs/NetworkCopilot.md Phase 5.
///
/// ```
/// ---
/// name: change-procedure
/// description: Pre-checks, steps, post-checks and rollback for any change
/// platforms: [linux, junos]
/// ---
/// <body>
/// ```
nonisolated struct AISkill: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case bundled
        case user
    }

    var name: String
    var description: String
    /// Metadata returned by `load_skill`; never filters the index.
    var platforms: [String]
    var body: String
    var source: Source
}

/// The skills one conversation sees, loaded once when the chat starts so the system prompt
/// (and with it the Anthropic cache prefix) stays fixed for the whole chat.
nonisolated struct AISkillSet: Sendable, Equatable {
    private(set) var skills: [AISkill]

    init(_ skills: [AISkill] = []) {
        self.skills = skills.sorted { $0.name < $1.name }
    }

    func skill(named name: String) -> AISkill? {
        skills.first { $0.name == name }
    }

    /// One line per skill for the system prompt.
    var indexLines: [String] {
        skills.map { "\($0.name) — \($0.description)" }
    }
}

nonisolated struct AISkillLibrary: Sendable {
    enum ParseError: LocalizedError, Equatable {
        case missingFrontMatter
        case missingField(String)
        case invalidName(String)
        case invalidDescription
        case emptyBody

        var errorDescription: String? {
            switch self {
            case .missingFrontMatter: "no front matter (--- name/description --- at the top)"
            case let .missingField(field): "front matter has no \(field)"
            case let .invalidName(name): "name '\(name)' must be lowercase letters, digits and hyphens"
            case .invalidDescription: "description must be one line of at most \(AISkillLibrary.maxDescriptionLength) characters"
            case .emptyBody: "the skill has no body"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.Skills")
    static let maxDescriptionLength = 200

    /// Bundled skills. Xcode's synchronized group flattens `Resources/Skills/*.md` into the
    /// bundle's resource root, so every `.md` there is a skill.
    var bundledDirectory: URL?
    /// The user's skills; a user skill with a bundled skill's name replaces it.
    var userDirectory: URL?

    static let empty = AISkillLibrary(bundledDirectory: nil, userDirectory: nil)

    static let standard = AISkillLibrary(
        bundledDirectory: Bundle.main.resourceURL,
        userDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ProSSHMac", isDirectory: true)
            .appendingPathComponent("Skills", isDirectory: true)
    )

    /// Reads both folders. A missing folder has no skills; an invalid file is logged and skipped.
    func load() -> AISkillSet {
        var byName: [String: AISkill] = [:]
        for skill in Self.skills(in: bundledDirectory, source: .bundled) {
            byName[skill.name] = skill
        }
        for skill in Self.skills(in: userDirectory, source: .user) {
            byName[skill.name] = skill
        }
        return AISkillSet(Array(byName.values))
    }

    /// Creates the user folder if needed, for "Open Skills Folder".
    func ensureUserDirectory() throws -> URL? {
        guard let userDirectory else { return nil }
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        return userDirectory
    }

    private static func skills(in directory: URL?, source: AISkill.Source) -> [AISkill] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return [] }
        var skills: [AISkill] = []
        var seen: Set<String> = []
        for file in files.filter({ $0.pathExtension.lowercased() == "md" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let skill = try parse(String(contentsOf: file, encoding: .utf8), source: source)
                guard seen.insert(skill.name).inserted else {
                    logger.error("skill_skipped file=\(file.lastPathComponent, privacy: .public) reason=duplicate name \(skill.name, privacy: .public)")
                    continue
                }
                skills.append(skill)
            } catch {
                logger.error("skill_skipped file=\(file.lastPathComponent, privacy: .public) reason=\(error.localizedDescription, privacy: .public)")
            }
        }
        return skills
    }

    static func parse(_ text: String, source: AISkill.Source) throws -> AISkill {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { throw ParseError.missingFrontMatter }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw ParseError.missingFrontMatter
        }

        var fields: [String: String] = [:]
        for line in lines[..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        guard let name = fields["name"], !name.isEmpty else { throw ParseError.missingField("name") }
        guard name.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }),
              name.first != "-" else { throw ParseError.invalidName(name) }
        // A description continued on the next line would leave that line without a key.
        guard let description = fields["description"], !description.isEmpty else {
            throw ParseError.missingField("description")
        }
        guard description.count <= maxDescriptionLength,
              lines[..<end].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.contains(":") }) else {
            throw ParseError.invalidDescription
        }

        let platforms = (fields["platforms"] ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let body = lines[lines.index(after: end)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ParseError.emptyBody }

        return AISkill(name: name, description: description, platforms: platforms, body: body, source: source)
    }
}
