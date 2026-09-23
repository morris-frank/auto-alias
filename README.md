<img src="brand/icon/icon-auto-alias-on-obsidian-512.png" align="left" width="128" hspace="16" alt="auto-alias icon">

<h3>auto-alias</h3>

<p>
  <sub>A ZSH HOOK, NOT A COMMAND</sub>
  <br>
  <strong>Tells you when a command you just typed already has an alias.</strong>
  <br>
  <br>
  <img src="https://img.shields.io/badge/shell-zsh-8EDE3D?style=flat-square&amp;labelColor=16211B" alt="zsh">
  <img src="https://img.shields.io/badge/built%20with-Rust-8EDE3D?style=flat-square&amp;labelColor=16211B" alt="Rust">
  <img src="https://img.shields.io/badge/per%20command-0.027%20ms-1AB172?style=flat-square&amp;labelColor=16211B" alt="0.027 ms per command">
  <img src="https://img.shields.io/badge/status-M1%3A%20match%20only-EE7931?style=flat-square&amp;labelColor=16211B" alt="Status M1: match only">
</p>

<br clear="left">

You never run it by hand except to install it. The hook compares what you typed against
your live alias table and, if a shorter form existed, prints one line after the command
finishes:

```
$ git status --short
On branch main
auto-alias: gs is 'git status' — 'gs --short' would have done it.
```

## Install

```sh
cargo install --locked --git https://github.com/morris-frank/auto-alias
echo 'eval "$(auto-alias init zsh)"' >> ~/.zshrc
exec zsh
```

To uninstall, delete that line from `~/.zshrc` by hand. If your `~/.zshrc` is a symlink
into a dotfiles repo, do not use `perl -ni` on it: that replaces the link with a regular
file and leaves the tracked original untouched.

## What it costs

Rule 1 is a hash lookup over `${(@kv)aliases}` inside the shell. No subprocess and no
file access per command. Measured on an M-series Mac with 50 aliases:

| path | per command |
|---|---|
| no match, the common case | 0.027 ms |
| match found | 0.027 ms |
| you used the alias already | 0.006 ms |
| reverse table build, on alias-count change | 0.14 ms |

A single `fork`+`exec` costs 1.13 ms on the same machine, so the whole hook is a small
fraction of the cheapest possible subprocess. `mise run test` fails the build if these
regress past the budget in [SPEC.md](SPEC.md) §8.

## Configuration

Optional, at `~/.config/auto-alias/aliases.zsh`, sourced at shell start:

```zsh
typeset -gA _aa_equiv
_aa_equiv[cd]=c        # "typing cd? c would have done it" — a semantic pair
```

Equivalence pairs cover the case where an alias is not a textual prefix of what you typed.
`c='z '` does not textually match `cd /tmp`, but it is what you meant. Nothing is guessed:
the tool is silent on these until you add the pair.

`AUTO_ALIAS_COOLDOWN` (default 3600) is the seconds before the same alias is mentioned
again. `NO_COLOR` is respected, and output goes to stderr only when it is a terminal.

## Scope

This is **M1**: rule 1 (match) only. Proposing *new* aliases from recurring commands is
M2/M3 and is not built yet. See [SPEC.md](SPEC.md) §14 for the milestones, §11 for what is
deliberately out of scope, and [docs/](docs/) for the drafts and reviews behind the design.

## Development

```sh
mise run setup    # toolchain, git hooks, verify
mise run check    # what CI runs: hooks + cargo tests + the zsh acceptance suite
```
