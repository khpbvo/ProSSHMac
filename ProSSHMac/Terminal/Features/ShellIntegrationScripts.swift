import Foundation

enum ShellIntegrationScripts: Sendable {

    /// Returns the multi-line OSC 133 integration script for the given shell type.
    /// Used for local shell overlay files (written to rc files, not echoed).
    /// Returns `nil` for types that don't use script injection (none, vendors, custom).
    static nonisolated func script(for type: ShellIntegrationType) -> String? {
        switch type {
        case .zsh:      return zshScript
        case .bash:     return bashScript
        case .fish:     return fishScript
        case .posixSh:  return posixShScript
        case .none, .custom,
             .ciscoIOS, .juniperJunOS, .aristaEOS, .mikrotikRouterOS,
             .paloAltoPANOS, .hpProCurve, .fortinetFortiOS, .nokiaSROS:
            return nil
        }
    }

    /// Returns a compact single-line version of the integration script for SSH injection.
    /// Prefixed with a space (suppresses bash history when HISTCONTROL=ignorespace).
    /// Returns `nil` for types that don't use script injection.
    static nonisolated func sshInjectionScript(for type: ShellIntegrationType) -> String? {
        switch type {
        case .zsh:      return sshZshScript
        case .bash:     return sshBashScript
        case .fish:     return sshFishScript
        case .posixSh:  return sshPosixShScript
        case .none, .custom,
             .ciscoIOS, .juniperJunOS, .aristaEOS, .mikrotikRouterOS,
             .paloAltoPANOS, .hpProCurve, .fortinetFortiOS, .nokiaSROS:
            return nil
        }
    }

    /// Returns the vendor prompt regex pattern string for the given type,
    /// or `nil` for types that don't use regex-based prompt detection.
    static nonisolated func vendorPromptPattern(for type: ShellIntegrationType) -> String? {
        switch type {
        case .ciscoIOS:         return #"^[A-Za-z][\w\-.:\/\[\]]*(\([^\)]+\))?[#>]\s*$"#
        case .juniperJunOS:     return #"^(\[[^\]]*\]\s+)?[\w\-.]+@[\w\-.]+[>#%]\s*$"#
        case .aristaEOS:        return #"^[\w\-\s]+(\([a-z\-]+\))?[#>]\s*$"#
        case .mikrotikRouterOS: return #"^\[[\w\-.]+@[\w\-.]+\]\s*(\(SAFE\)\s*)?(/[\w/\-.]*)?>\s*$"#
        case .paloAltoPANOS:    return #"^(\[edit[^\]]*\]\s+)?[\w\-.]+@[\w\-.]+[>#]\s*$"#
        case .hpProCurve:       return #"^[A-Za-z0-9][\w\-.]*(\(config[a-z\-]*\))?[#>]\s*$"#
        case .fortinetFortiOS:  return #"^[A-Za-z0-9][\w\-.]*(\s*\([\w\s\-]+\))?[#$]\s*$"#
        case .nokiaSROS:        return #"^[A-Z]:[\w\-.]+(\[/[\w\-.]*\])?[>#]\s*$"#
        case .custom:           return nil
        default:                return nil
        }
    }

    // MARK: - Multi-line scripts (for local shell overlay rc files)

    private nonisolated static var zshScript: String {
        """
        if [[ -z "$__PROSSH_SHELL_INTEGRATION" ]]; then
          export __PROSSH_SHELL_INTEGRATION=1
          autoload -Uz add-zsh-hook
          __prossh_precmd() {
            local ec=$?
            printf '\\e]133;D;%d\\e\\\\' "$ec"
            printf '\\e]133;A\\e\\\\'
          }
          __prossh_preexec() {
            printf '\\e]133;C\\e\\\\'
          }
          add-zsh-hook precmd __prossh_precmd
          add-zsh-hook preexec __prossh_preexec
          printf '\\e]133;A\\e\\\\'
        fi
        """
    }

    private nonisolated static var bashScript: String {
        """
        if [ -z "$__PROSSH_SHELL_INTEGRATION" ]; then
          export __PROSSH_SHELL_INTEGRATION=1
          __prossh_prompt_cmd() {
            local ec=$?
            printf '\\e]133;D;%d\\e\\\\' "$ec"
            printf '\\e]133;A\\e\\\\'
          }
          PROMPT_COMMAND="__prossh_prompt_cmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
          __prossh_debug_trap() {
            if [[ "$BASH_COMMAND" != "$PROMPT_COMMAND"* ]]; then
              printf '\\e]133;C\\e\\\\'
            fi
            return 0
          }
          trap '__prossh_debug_trap' DEBUG
          printf '\\e]133;A\\e\\\\'
        fi
        """
    }

    private nonisolated static var fishScript: String {
        """
        if not set -q __PROSSH_SHELL_INTEGRATION
          set -gx __PROSSH_SHELL_INTEGRATION 1
          function __prossh_prompt --on-event fish_prompt
            set -l ec $status
            printf '\\e]133;D;%d\\e\\\\' $ec
            printf '\\e]133;A\\e\\\\'
          end
          function __prossh_preexec --on-event fish_preexec
            printf '\\e]133;C\\e\\\\'
          end
          printf '\\e]133;A\\e\\\\'
        end
        """
    }

    private nonisolated static var posixShScript: String {
        """
        if [ -z "$__PROSSH_SHELL_INTEGRATION" ]; then
          __PROSSH_SHELL_INTEGRATION=1; export __PROSSH_SHELL_INTEGRATION
          PS1="$(printf '\\033]133;A\\033\\\\')${PS1}$(printf '\\033]133;B\\033\\\\')"
          export PS1
        fi
        """
    }

    // MARK: - Compact single-line scripts (for SSH raw injection)
    // Leading space suppresses bash history (HISTCONTROL=ignorespace).

    // swiftlint:disable line_length
    private nonisolated static var sshZshScript: String {
        #" if [[ -z "$__PROSSH_SHELL_INTEGRATION" ]]; then export __PROSSH_SHELL_INTEGRATION=1; autoload -Uz add-zsh-hook; __prossh_precmd() { local ec=$?; printf '\e]133;D;%d\e\\' "$ec"; printf '\e]133;A\e\\'; }; __prossh_preexec() { printf '\e]133;C\e\\'; }; add-zsh-hook precmd __prossh_precmd; add-zsh-hook preexec __prossh_preexec; printf '\e]133;A\e\\'; fi"#
    }

    private nonisolated static var sshBashScript: String {
        #" if [ -z "$__PROSSH_SHELL_INTEGRATION" ]; then export __PROSSH_SHELL_INTEGRATION=1; __prossh_prompt_cmd() { local ec=$?; printf '\e]133;D;%d\e\\' "$ec"; printf '\e]133;A\e\\'; }; PROMPT_COMMAND="__prossh_prompt_cmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"; __prossh_debug_trap() { if [[ "$BASH_COMMAND" != "$PROMPT_COMMAND"* ]]; then printf '\e]133;C\e\\'; fi; return 0; }; trap '__prossh_debug_trap' DEBUG; printf '\e]133;A\e\\'; fi"#
    }

    private nonisolated static var sshFishScript: String {
        #" if not set -q __PROSSH_SHELL_INTEGRATION; set -gx __PROSSH_SHELL_INTEGRATION 1; function __prossh_prompt --on-event fish_prompt; set -l ec $status; printf '\e]133;D;%d\e\\' $ec; printf '\e]133;A\e\\'; end; function __prossh_preexec --on-event fish_preexec; printf '\e]133;C\e\\'; end; printf '\e]133;A\e\\'; end"#
    }

    private nonisolated static var sshPosixShScript: String {
        #" if [ -z "$__PROSSH_SHELL_INTEGRATION" ]; then __PROSSH_SHELL_INTEGRATION=1; export __PROSSH_SHELL_INTEGRATION; PS1="$(printf '\033]133;A\033\\')${PS1}$(printf '\033]133;B\033\\')"; export PS1; fi"#
    }
    // swiftlint:enable line_length
}
