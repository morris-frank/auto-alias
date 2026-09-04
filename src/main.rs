//! auto-alias M1 — the binary's only job is to print the shell integration.
//!
//! Rule 1 (match) runs entirely inside zsh; nothing here is on the prompt path.
//! See SPEC.md §14 for the milestones that add `analyze`, `add` and `doctor`.

/// The snippet is compiled in so the binary is the single artifact to install.
const INIT_ZSH: &str = include_str!("../shell/init.zsh");

const USAGE: &str = "\
auto-alias — tells you when a command you typed already has an alias.

usage:
  auto-alias init zsh     print the zsh integration; add to ~/.zshrc as:
                            eval \"$(auto-alias init zsh)\"
  auto-alias --version
  auto-alias --help
";

fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let words: Vec<&str> = args.iter().map(String::as_str).collect();

    match words.as_slice() {
        ["init", "zsh"] => {
            print!("{INIT_ZSH}");
            std::process::ExitCode::SUCCESS
        }
        ["init", other] => {
            // Fail loudly: a silently wrong shell would leave the user with no hooks
            // and no error to explain why nothing ever fires.
            eprintln!("auto-alias: unsupported shell {other:?}; only zsh is supported");
            std::process::ExitCode::FAILURE
        }
        ["init"] => {
            eprintln!("auto-alias: `init` needs a shell, e.g. `auto-alias init zsh`");
            std::process::ExitCode::FAILURE
        }
        ["--version" | "-V"] => {
            println!("auto-alias {}", env!("CARGO_PKG_VERSION"));
            std::process::ExitCode::SUCCESS
        }
        ["--help" | "-h"] | [] => {
            print!("{USAGE}");
            std::process::ExitCode::SUCCESS
        }
        _ => {
            eprintln!(
                "auto-alias: unknown command {:?}\n\n{USAGE}",
                args.join(" ")
            );
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::INIT_ZSH;

    #[test]
    fn snippet_is_embedded_and_installs_both_hooks() {
        assert!(INIT_ZSH.contains("add-zsh-hook preexec __aa_preexec"));
        assert!(INIT_ZSH.contains("add-zsh-hook precmd  __aa_precmd"));
    }

    #[test]
    fn snippet_refuses_non_interactive_shells() {
        // Sourcing in a script must be a no-op; the first line is what guarantees it.
        assert!(
            INIT_ZSH
                .lines()
                .any(|l| l.trim() == "[[ -o interactive ]] || return 0")
        );
    }

    #[test]
    fn m1_carries_no_binary_call_and_no_state_dir() {
        // M1's hot path must not fork or touch the filesystem (SPEC.md §8).
        assert!(!INIT_ZSH.contains("auto-alias analyze"));
        assert!(!INIT_ZSH.contains("AUTO_ALIAS_STATE"));
    }
}
