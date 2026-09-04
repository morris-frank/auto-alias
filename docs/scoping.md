---
date: 2026-09-04
status: input to spec drafting
---

# auto-alias — scoping brief

Input for the competing-spec drafts. Facts first, then constraints, then open decisions.

## The ask (operator, verbatim intent)

A CLI tool that is never called by hand except for install and config. It keeps its own registry of
aliases and functions. Every command the user runs is checked against the registry:

1. **Match** — the command matches an existing alias exactly (or, optionally, fuzzily), or would be
   shorter with one. Tell the user.
2. **Propose** — recurring commands, chained calls (`a && b`, `a | b`), and long invocations are
   proposed as new aliases.

Both produce a *minimal but functional* one-liner, e.g. `This could be an alias, add with: ...`.

Non-negotiables: unintrusive, simple set-up, **never blocking**, stable, clean KISS codebase.
zoxide and mise are the reference architectures. Python discouraged. Otherwise no restriction.

## Operator environment (observed)

| item | value |
|---|---|
| interactive shell | zsh 5.9 (bash on remotes — remote support is a nice-to-have, not a goal) |
| dotfiles | `~/.zshrc` is a symlink into a git-tracked config repo; chezmoi under consideration |
| toolchain present | mise, fzf, gum, llm, zoxide, starship, rustc/cargo 1.98, bun 1.4, deno 2.9, node 26. **No go**, no python outside mise. |
| history | `~/.zsh_history`, 26k lines, `SHARE_HISTORY`, **no `EXTENDED_HISTORY`** → no timestamps in the file |
| existing aliases | 37 aliases + several functions, defined inline in `.zshrc` (git-heavy: `g`, `gs`, `gd`, `gsm`, `gcpr`, ...; `c='z '`, `m='mise '`, `cl='claude '`) |

## Evidence from the real history (why this tool is worth building)

Counts from the current history file:

| signal | count | which rule fires |
|---|---|---|
| `git …` typed although `g='git '` exists | 1108 | match (alias exists) |
| `cd …` typed although `c='z '` and zoxide exist | 790 | match (semantic equivalent) |
| `mise …` typed although `m='mise '` exists | 456 | match (alias exists) |
| `hubspot-conversations-fetch` (exact line) | 21 | propose (recurring long command) |
| `codex-session-fetch` | 8 | propose |
| `./hubspot-conversations-fzf` | 8 | propose |
| `mise run typecheck` | 5 | propose (or note `m` exists → `m run typecheck`) |
| `command find . -name '*.py' -type f -exec wc -l {} + \| sort -r \| fzf` | 3 | propose (chained pipeline) |
| `claude --teleport <id>` | 4 | propose (prefix recurs, argument varies → function, not alias) |

Takeaways: the "match" rule alone has ~2350 occasions to fire on this history. Recurrence thresholds
must count *normalized* commands (strip trailing whitespace, collapse spaces) — several duplicates
differ only by a trailing space. Some proposals need a parameter (`claude --teleport $1`), i.e. a
function, not an alias.

## Reference architectures

**zoxide** — `eval "$(zoxide init zsh)"` prints a shell snippet. The snippet registers one
`chpwd_functions` hook that runs `zoxide add -- "$PWD"` (fire-and-forget, tiny binary call). State
is a single local DB file. A `__zoxide_doctor` check warns once if the hook isn't installed. Single
static binary, no daemon, no config file required.

**mise** — `eval "$(mise activate zsh)"` prints a snippet that removes any previous hook with
`add-zsh-hook -d` (idempotent re-source), then registers `precmd`/`chpwd` hooks calling
`mise hook-env -s zsh` and `eval`-ing the result. Hook cost is kept low with a fast path.

**atuin** (not installed, pattern only) — `preexec` records command start, `precmd` records exit
code + duration; SQLite store; optional daemon. Shows what a full history recorder costs.

**zsh-you-should-use / alias-tips** (prior art for rule 1) — pure-zsh `preexec` hook that looks up
the typed command in `alias` output and prints "Found existing alias for …". alias-tips is Python
(slow startup, hence the operator's Python aversion). Neither proposes new aliases. Neither keeps
a registry — they read live `alias` output.

**fish `abbr` / zsh-abbr** — expand on space; different interaction model (expansion, not advice).
Not what is asked, but shows where "registry of short forms" already lives in some shells.

## Zsh hook facts that constrain the design

- `preexec` receives the command line **before** alias expansion (`$1` typed, `$2` expanded single
  line, `$3` full expanded). This is the only place the raw typed string is available.
- `precmd` runs before each prompt; anything printed there lands above the prompt. `$?` of the
  previous command is available.
- Hooks run in the foreground shell. Anything slower than a few ms per prompt is felt. Never-blocking
  therefore means: hook does at most a `print` plus a backgrounded call, or a cheap lookup against
  preloaded shell data.
- Output from a backgrounded job arrives asynchronously and can corrupt the prompt line. The known
  clean ways are (a) print from `precmd` synchronously from cached state, (b) `zle -F` fd watcher
  (zsh-autosuggestions/async pattern), (c) defer the message to the *next* prompt.
- `alias -L` / `functions` dump the live definitions; `whence -w` classifies a word (alias/function/
  command/builtin) in one call.
- Bash on remotes has no `preexec` (needs `DEBUG` trap or bash-preexec). Treat as out of scope or
  degrade to a `PROMPT_COMMAND` + `history 1` approximation.

## Constraints for every draft

1. Install is one line in `.zshrc` (`eval "$(auto-alias init zsh)"` or equivalent) plus one install
   step (brew/cargo/mise/curl). Uninstall = remove that line + delete the state dir.
2. Never blocking: hard budget of a few ms of synchronous work per prompt; no network; no LLM in the
   hot path. Heavy analysis runs out of band (background, throttled, or on demand).
3. Registry is a plain file in `$XDG_DATA_HOME/auto-alias/` or `$XDG_CONFIG_HOME/auto-alias/`, human
   readable, diff-able, safe to put under dotfile management (chezmoi/git).
4. Output is one line, plain text, no chrome; respects `NO_COLOR`; silent when nothing to say;
   rate-limited (don't nag about the same alias every prompt).
5. Proposals must be *functional*: emit the exact `alias x='…'` or function body ready to paste, and
   say where to add it (or offer `auto-alias add x` that appends to a managed file that `.zshrc`
   sources).
6. Registry vs live shell: the tool must handle aliases defined outside its registry (the 37 existing
   ones). Decide: import once, sync each shell start, or read live `alias -L` each time.
7. Python discouraged. A shell-only solution is allowed if it can stay KISS and fast.
8. Codebase: one binary or one plugin, small, testable, no framework sprawl. Optional integrations
   (fzf picker, gum styling, llm for naming suggestions) are opt-in extras, never dependencies.

## Open decisions the drafts must take a position on

- D1 Language/runtime: Rust single binary (zoxide/mise pattern) vs pure zsh plugin vs Bun/Deno
  compiled binary vs Go (not installed today).
- D2 Where analysis runs: in the `preexec` hook, in `precmd`, backgrounded per command, periodic
  batch over `$HISTFILE`, or on shell start.
- D3 Data source for "recurring": the tool's own log of commands vs reading `$HISTFILE` (no
  timestamps here; SHARE_HISTORY interleaves sessions).
- D4 Fuzzy matching: what "fuzzy" means (prefix of an alias expansion? edit distance? subsequence?)
  and whether it is in v1 at all.
- D5 Proposal thresholds and naming: N repeats in window W; how to pick a short name that doesn't
  collide with existing commands (`whence`).
- D6 How the user acts on a proposal: copy-paste only, `auto-alias add`, or interactive accept
  (gum/fzf) — and whether accept is in v1.
- D7 Message delivery: same prompt (synchronous), next prompt (deferred), or async fd watcher.
- D8 Bash-on-remote: out of scope for v1?

## Verified measurements (run on this machine, 2026-09-04)

These are measured, not assumed. Drafts must build on them.

**preexec argument semantics** — `$1` is the raw typed line, `$2`/`$3` are alias-expanded:

| typed | `$1` | `$2` |
|---|---|---|
| `gs` | `gs` | `git status` |
| `git status` | `git status` | `git status` |
| `ls -la \| head -2 && echo hi` | unchanged | unchanged (no alias in play) |

Consequence: **`[[ "$1" == "$2" ]]` means no alias expansion happened.** Combined with a reverse lookup
of `$2` in the alias table, that is the whole of rule 1's exact-match detection — no parsing needed.

**Hot-path costs**

| operation | measured |
|---|---|
| one `fork`+`exec` of a trivial binary | **1.17 ms** (100 forks = 116.9 ms) |
| one zsh associative-array lookup | **0.0007 ms** (10 000 lookups = 7.2 ms) |
| building a 37-entry reverse table from `alias -L` | **0.91 ms**, once per shell start |
| `zoxide query --list` (real small binary) | ~8 ms |

Consequence: an in-shell lookup is ~1700× cheaper than the cheapest possible binary call. Any design that
forks per command pays at least 1.2 ms; a design that forks only when it has something to say pays nothing
on the common path.

**History file** — `od -c ~/.zsh_history` shows bare command lines with no `: <epoch>:<dur>;` prefix.
`EXTENDED_HISTORY` is off, so **there are no timestamps**. Recurrence analysis over `$HISTFILE` has no time
dimension: no "N times in the last week", only "N times in the last 26 771 commands".

**Normalization is load-bearing** — the real aliases carry trailing spaces (`gs='git status '`). A reverse
lookup that does not trim trailing whitespace on both sides misses every one of them. Verified: an untrimmed
build of the reverse table failed to match `git status`.

**`whence -w` classifies in one call**: returns `alias`, `function`, `command`, `builtin`, or `none`.
That is the collision check for proposed names.

> **Correction (2026-09-04).** The first version of the table above under-counted by roughly 20x. The counting
> pipeline used `sed` on a history file containing non-UTF-8 bytes; `sed` aborted with `RE error: illegal byte
> sequence` and the truncated output was tallied as if complete. Recounted byte-safely with `awk` over all
> 26 849 lines. Lesson for the tool itself: **any component that reads `$HISTFILE` must be byte-safe and must
> fail loudly, not silently truncate.** Top first words: `ls` 3542, `z` 3313, `q` 2085, `gs` 1206, `git` 1117,
> `m` 1046, `cd` 814, `claude` 558.
