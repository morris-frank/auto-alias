---
date: 2026-09-04
status: draft
angle: A — zoxide pattern, one small Rust binary
---

# auto-alias — draft A: one Rust binary, all hot-path work in zsh

## 1. Summary

One static Rust binary plus one emitted zsh snippet, zoxide-style. The shell owns the hot path: rule 1
is a pure in-shell hash lookup built from `${(kv)aliases}` — zero forks per command, measured 0.07 ms.
The binary is never on the critical path; it is spawned detached every 50 commands to mine an
append-only log and write one proposal line that the next `precmd` prints. No async runtime, no
daemon, no clap, no external crates. Fuzzy matching is out of v1.

## 2. Architecture

| component | role |
|---|---|
| `auto-alias` (Rust, ~600 LOC) | `init`, `analyze`, `add`, `list`, `mute`, `doctor` — never called in the hot path |
| emitted zsh snippet (81 lines) | reverse alias table, rule 1, log append, deferred printing |
| `~/.config/auto-alias/aliases.zsh` | the managed alias file, sourced by the snippet |
| `~/.config/auto-alias/config` | equivalences, mutes, thresholds |
| `~/.local/share/auto-alias/{log,pending,shown}` | append-only log, one pending proposal, shown history |

```
preexec ─(builtin append, no fork)─▶ log ─▶ every 50 cmds: `auto-alias analyze &!` (detached)
   └─ in-shell reverse lookup ─▶ _aa_msg          │  group ▸ threshold ▸ name ▸ pending (atomic rename)
precmd ─── prints _aa_msg, else reads pending, validates the name against the live shell, prints, deletes
```

**What `auto-alias init zsh` emits** — tested end to end in a real interactive zsh:

```zsh
# auto-alias 0.1 — zsh integration, emitted by `auto-alias init zsh`. Do not edit.
zmodload zsh/datetime
zmodload -F zsh/files b:zf_rm b:zf_mkdir

typeset -gA _aa_rev _aa_equiv _aa_seen
typeset -g  _aa_msg='' _aa_d='' _aa_o=''
[[ -z $NO_COLOR && -o interactive ]] && { _aa_d=$'\e[2m'; _aa_o=$'\e[0m' }
typeset -gi _aa_n=0 _aa_boot=0
: ${AUTO_ALIAS_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/auto-alias}
: ${AUTO_ALIAS_STATE:=${XDG_DATA_HOME:-$HOME/.local/share}/auto-alias}
: ${AUTO_ALIAS_EVERY:=50}
: ${AUTO_ALIAS_COOLDOWN:=3600}
[[ -d $AUTO_ALIAS_STATE ]] || zf_mkdir -p $AUTO_ALIAS_STATE
[[ -r $AUTO_ALIAS_HOME/aliases.zsh ]] && source $AUTO_ALIAS_HOME/aliases.zsh

__aa_table() {
  local n b
  _aa_rev=()
  for n b in ${(kv)aliases}; do
    b=${(j: :)${(z)b}}
    [[ -n $b && ${#n} -lt ${#b} && -z ${_aa_rev[$b]} ]] && _aa_rev[$b]=$n
  done
  local l
  [[ -r $AUTO_ALIAS_HOME/config ]] || return 0
  for l in ${(f)"$(<$AUTO_ALIAS_HOME/config)"}; do
    [[ $l == equiv\ * ]] || continue
    l=${l#equiv }
    _aa_equiv[${l%%|*}]=${l#*|}
  done
}

__aa_preexec() {
  local raw=${(j: :)${(z)1}} low
  [[ $1 == ' '* || -z $raw ]] && return 0
  low=${raw:l}
  if [[ $1 == $2 && $low != *token* && $low != *secret* && $low != *password* \
        && $low != *api?key* && $low != *bearer* && $low != *credential* ]]; then
    print -r -- "$EPOCHSECONDS	$raw" >> $AUTO_ALIAS_STATE/log
  fi
  (( ++_aa_n % AUTO_ALIAS_EVERY == 0 )) && { auto-alias analyze &! } 2>/dev/null
  [[ $1 == $2 ]] || return 0            # an alias was already used
  local -a w=(${(z)raw})
  local i k n cand e=${_aa_equiv[${w[1]}]}
  if [[ -n $e ]] && (( EPOCHSECONDS - ${_aa_seen[$e]:-0} >= AUTO_ALIAS_COOLDOWN )); then
    _aa_seen[$e]=$EPOCHSECONDS
    _aa_msg="auto-alias: $e replaces ${w[1]} here — '$e ${(j: :)w[2,-1]}'."
    return 0
  fi
  for (( i = $#w; i > 0; i-- )); do
    k=${(j: :)w[1,i]}
    n=${_aa_rev[$k]}
    [[ -n $n ]] || continue
    cand=$n; (( i < $#w )) && cand="$n ${(j: :)w[i+1,-1]}"
    (( $#raw - $#cand >= 2 )) || return 0
    (( EPOCHSECONDS - ${_aa_seen[$n]:-0} < AUTO_ALIAS_COOLDOWN )) && return 0
    _aa_seen[$n]=$EPOCHSECONDS
    _aa_msg="auto-alias: $n is '$k' — '$cand' would have done it."
    return 0
  done
}

__aa_free() { (( ! ${+aliases[$1]} && ! ${+functions[$1]} && ! ${+builtins[$1]} && ! ${+commands[$1]} && ! ${+reswords[$1]} )) }

__aa_precmd() {
  (( _aa_boot++ )) || __aa_table   # first prompt: the whole .zshrc has run, order no longer matters
  if [[ -n $_aa_msg ]]; then print -ru2 -- $_aa_d$_aa_msg$_aa_o; _aa_msg=''; return 0; fi
  [[ -s $AUTO_ALIAS_STATE/pending ]] || return 0
  local l nm body
  for l in ${(f)"$(<$AUTO_ALIAS_STATE/pending)"}; do
    nm=${l%%	*}; body=${${l#*	}%%	*}
    __aa_free $nm && [[ -z ${_aa_rev[$body]} ]] || continue
    print -ru2 -- $_aa_d${l##*	}$_aa_o
    print -r -- "$nm	$body" >> $AUTO_ALIAS_STATE/shown
    break
  done
  zf_rm -f $AUTO_ALIAS_STATE/pending
}

autoload -Uz add-zsh-hook
add-zsh-hook -d preexec __aa_preexec; add-zsh-hook preexec __aa_preexec
add-zsh-hook -d precmd  __aa_precmd;  add-zsh-hook precmd  __aa_precmd
```

Verified by piping `git status --short` and `cd /tmp` into `zsh -i`: both messages appear above the
next prompt (see section 7). Placement in `.zshrc` does not matter — the table is built on the first
`precmd`, after the rc file has run.

## 3. Install / uninstall

```sh
cargo install --locked auto-alias          # or: mise use -g cargo:auto-alias / brew install auto-alias
echo 'eval "$(auto-alias init zsh)"' >> ~/.zshrc
exec zsh && auto-alias doctor              # doctor prints hook state, table size, log size
```

```sh
sed -i '' '/auto-alias init zsh/d' ~/.zshrc
cat ~/.config/auto-alias/aliases.zsh >> ~/.zshrc   # keep the aliases it created, if wanted
rm -rf ~/.config/auto-alias ~/.local/share/auto-alias && cargo uninstall auto-alias
```

## 4. Registry format

`~/.config/auto-alias/aliases.zsh` — the registry *is* executable zsh, appended to by `auto-alias add`:

```zsh
# auto-alias managed aliases — sourced by the init snippet. Safe to edit or move into .zshrc.
alias hcf='hubspot-conversations-fetch '        # added 2026-09-04, seen 16x
alias csf='codex-session-fetch '                # added 2026-09-04, seen 8x
clt() { claude --teleport "$@"; }               # added 2026-09-04, seen 4x, tail varies
```

`~/.config/auto-alias/config`:

```
repeats = 5          # defaults, all optional
window  = 30d
minsave = 8
equiv cd|c           # `cd X` is served by `c` (= z X) although the strings differ
mute hubspot-conversations-fzf
```

**D6 / constraint 6: there is no separate alias registry.** The live shell alias table is the registry.
`__aa_table` reads `${(kv)aliases}`, a fork-free zsh parameter, so the 37 `.zshrc` aliases and the ones
in `aliases.zsh` are indistinguishable and always current — nothing imported, nothing synced, no drift.
Aliases whose name is not shorter than their body are dropped; first name wins on a shared body.

## 5. Rule 1 — match

Exact only in v1, entirely in `preexec`, no fork.

1. Normalize: `${(j: :)${(z)$1}}` word-splits and rejoins with single spaces — trims and collapses on
   both sides. This is the load-bearing step the brief flags (`gs='git status '`).
2. `[[ $1 != $2 ]]` → an alias already expanded → return.
3. Word 1 in `_aa_equiv` → emit the equivalence message. This is the 41 `cd` hits; `cd`→`c` saves one
   character, so it must bypass the length threshold.
4. Else walk word prefixes longest-first (`w[1..n]`, `w[1..n-1]`, …), one 0.0007 ms hash lookup each;
   first hit wins, rewrite = alias name + remaining words (12-word worst case ≈ 0.01 ms). Suppress
   unless it saves ≥ 2 chars and the name's cooldown has expired.

Finds `git status`→`gs`, `git status --short`→`gs --short`, `cd ..`→`..`.

**Fuzzy: not in v1.** Every candidate definition (edit distance, subsequence, flag-order-insensitive)
needs a command-line parser, a scoring function and a false-positive budget — cost far above its value
while exact matching already fires ~80 times on the real history. The log makes the case measurable later.

## 6. Rule 2 — propose

`analyze` reads the last 20 000 log lines, keeps entries inside the window (30 days — the log carries
real `EPOCHSECONDS`, unlike `$HISTFILE`), and drops muted and recently-shown bodies.

Normalization happens at write time in the shell, so the binary compares byte-equal strings. Lines
starting with a space are never logged, nor are lines where an alias expanded.

| group | trigger | threshold | emits |
|---|---|---|---|
| A exact repeat | identical normalized line | ≥ 5 occurrences, ≥ 2 distinct days, body ≥ 12 chars, saving ≥ 8 | alias |
| B varying tail | drop last token, group by prefix of ≥ 2 words | ≥ 5 occurrences with ≥ 3 distinct tails | function |
| C chained | body contains ` && `, ` \|\| `, ` \| ` or `; ` | ≥ 3 occurrences | alias; function if the body contains `'` |

Ranked by `count × (len(body) − len(name))`; only the top one is written to `pending`.

**Naming.** Initials of the words, splitting on space/`-`/`_`, skipping `-flags` and tokens containing
`/`: `hubspot-conversations-fetch`→`hcf`, `mise run typecheck`→`mrt`, `claude --teleport`→`clt`. The
binary emits up to four candidates (`hcf`, `hcfe`, `hubcf`, `hc-fetch`) and cannot check collisions
itself — a binary cannot see zsh functions or aliases. The **shell** picks the first free one at print
time via `${+aliases[x]}`, `${+functions[x]}`, `${+builtins[x]}`, `${+commands[x]}`, `${+reswords[x]}`:
five parameter lookups, no fork, exactly the classification `whence -w` performs (`auto-alias add`
shells out to `whence -w` for the same check). The shell also skips a proposal when `_aa_rev[body]`
already exists, so rule 2 can never propose what rule 1 covers.

**Alias vs function** follows the group: A and C give `alias n='body '` (trailing space, so the next
word is itself alias-expanded — the operator's existing style); B gives `n() { prefix "$@"; }`.

## 7. Output & delivery

```
auto-alias: gs is 'git status' — 'gs --short' would have done it.
auto-alias: c replaces cd here — 'c /tmp/foo'.
auto-alias: 'hubspot-conversations-fetch' ran 16x in 30d. Add it: auto-alias add hcf 'hubspot-conversations-fetch '
auto-alias: 'claude --teleport …' ran 4x with 4 different arguments. Add it: auto-alias add --fn clt 'claude --teleport'
```

One line, to stderr, dimmed with `\e[2m` unless `NO_COLOR` is set or the shell is not interactive.
Silent whenever there is nothing to say.

**Rate limiting.** One message per prompt, rule 1 before rule 2. Per-name cooldown 3600 s, session-local
in `_aa_seen`. One live proposal at a time: `analyze` refuses to overwrite an existing `pending`, and a
printed proposal is appended to `shown` and suppressed 14 days. `auto-alias mute <name>` makes it permanent.

**D7 — deferred, never async.** The message is computed in `preexec` and printed by the next `precmd`,
landing immediately above the next prompt from a synchronous `print` of cached state. No backgrounded
process ever writes to the terminal, so no `zle -F` fd watcher and no prompt-corruption class exists.

## 8. Never-blocking guarantee

Measured here (zsh 5.9.2, aarch64), 1000 iterations each:

| synchronous work | cost |
|---|---|
| `__aa_preexec`, no match, incl. log append | **0.075 ms** |
| `__aa_preexec`, match found | **0.069 ms** |
| `__aa_precmd`, nothing pending | **0.006 ms** |
| `__aa_table`, once per shell start | **0.13 ms** (fork-free; the brief's 0.91 ms came from `$(alias -L)`, which forks) |
| detached `analyze &!`, amortised over 50 commands | **0.008 ms** |

Budget: **0.2 ms per prompt, p99**; forks per command on the common path: **0**. `mise run bench` runs
these loops under `zsh -f` and fails the build if `preexec × 1000 > 200 ms`.
Binary missing or renamed: rule 1 is unaffected — it never calls the binary. The single call site is
`{ auto-alias analyze &! } 2>/dev/null`, verified silent with no binary on `$PATH`. Binary slow: it is
detached with `&!` so the shell never waits, takes `state/analyze.lock` via `O_EXCL` so overlapping
spawns exit at once, and aborts after a 2 s self-imposed wall clock. Corrupt `pending`: malformed lines
fail the field split and are skipped, and the file is deleted after every read.

## 9. Positions on D1–D8

- **D1** Rust, one static binary, std only, no clap, no async runtime — zoxide's shape, and the only compiled toolchain already installed (rustc 1.98).
- **D2** Rule 1 in `preexec` (in-shell, no fork); rule 2 in a detached binary every 50 commands. Nothing on shell start, nothing periodic, no daemon.
- **D3** The tool's own log. `$HISTFILE` has no timestamps here and `SHARE_HISTORY` interleaves sessions; the log costs one builtin append and carries `EPOCHSECONDS`.
- **D4** No fuzzy matching in v1: exact normalized prefix matching plus explicit `equiv` lines for semantic pairs like `cd`/`c`.
- **D5** ≥ 5 repeats in 30 days on ≥ 2 distinct days, saving ≥ 8 chars (≥ 3 for pipelines); names from word initials, collisions resolved in the shell against the live tables.
- **D6** Copy-paste or `auto-alias add <name> <body>`, appending to `aliases.zsh`. No interactive accept in v1 — fzf/gum buys nothing a one-line command does not.
- **D7** Deferred to the next `precmd`, printed synchronously from shell state.
- **D8** Bash on remotes is out of scope for v1; `auto-alias init bash` prints an explicit "unsupported" rather than a half-working `DEBUG` trap.

## 10. Codebase

Rust 2024, `rust = "1.98"` added to `mise.toml`. **Dependencies: none** — `std::{time,fs,env,process}`
covers everything; argument parsing is a `match` on `args().nth(1)`.

| file | LOC | contents |
|---|---|---|
| `shell/init.zsh` | 81 | the snippet above, `include_str!`'d into the binary |
| `src/main.rs` | 90 | subcommand match, paths, exit codes |
| `src/paths.rs` | 40 | XDG resolution, lockfile, atomic write + rename |
| `src/log.rs` | 80 | append, tail-read 20 000 lines, rotate at 2 MB, secret backstop |
| `src/group.rs` | 150 | the three groups and their thresholds |
| `src/name.rs` | 70 | initial-based candidate names |
| `src/render.rs` | 60 | `pending` lines and `auto-alias add` output |
| `src/add.rs` | 70 | append to `aliases.zsh`, `whence -w` collision check |

**Tests.** `cargo test` covers `group`/`name`/`log` against fixture logs derived from the real
`~/.zsh_history` (checked in, scrubbed). `tests/shell.zsh` sets `HOME` to a temp dir, pipes commands
into `zsh -i` and asserts on stderr — the harness used to verify the snippet above. `mise run bench`
enforces the hot-path budget.

**Tooling.** `mise.toml` gains `rust`, `[tasks.test] = "cargo test && tests/shell.zsh"`,
`[tasks.lint] = "cargo clippy -- -D warnings && cargo fmt --check"` and `[tasks.bench]`, with
`[tasks.check]` depending on both. `prek` gains a local `zsh -n shell/init.zsh` hook; `shell/init.zsh`
is excluded from `shellcheck`, which does not speak zsh. CI needs no other change.

## 11. v1 scope and non-goals

**In:** exact match with prefix rewrite and `equiv` pairs; the three proposal groups; `init`, `analyze`,
`add`, `list`, `mute`, `doctor`; the two config files; deferred one-line output; cooldowns.

**Out:** fuzzy matching; interactive accept (fzf/gum); LLM naming; bash, fish, remote shells; a daemon;
network anything; automatic editing of `.zshrc`; per-directory aliases; TUI; telemetry.

## 12. Risks and failure modes

- **Prompt corruption** — structurally impossible: only a synchronous `print` in `precmd` writes to the terminal; the detached `analyze` has no output.
- **`SHARE_HISTORY` interleaving** — irrelevant, the tool never reads `$HISTFILE`. Its own log is `O_APPEND`, atomic per line below `PIPE_BUF` (4 KB); the shell truncates logged lines at 2 KB and `analyze` drops lines not starting with `<digits>\t`.
- **Alias collisions** — the shell, not the binary, validates every proposed name against the live alias/function/builtin/command/reserved-word tables at print time, so a name taken since analysis is never suggested; `auto-alias add` re-checks and refuses.
- **Remote bash** — no hooks, so no logging and no advice; the tool is simply absent and locally added aliases do not travel. Accepted for v1.
- **Multi-shell** — many shells append to one log and race on `pending`. The lock serialises `analyze`; `pending` is replaced by `rename(2)`, so a reader sees old or new, never partial. Cooldowns are per-session, so one tip can appear once in each of several shells.
- **Secrets in the log** — the shell skips lines starting with a space and lines whose lowercase form contains `token`, `secret`, `password`, `api?key`, `bearer` or `credential`; `log.rs` reapplies the filter on read. A heuristic, not a guarantee: a positional secret (`deploy abc123def`) is logged. The log lives in `$XDG_DATA_HOME` at mode 0600, is state rather than config so dotfile managers do not sync it, and `auto-alias log --purge <pattern>` removes matching lines. Say this plainly in the README instead of implying safety.
- **Threshold miscalibration** — 5 repeats in 30 days may be too eager for exploratory work. The numbers live in `config`, and `auto-alias analyze --dry-run` prints what it *would* have proposed over the existing log; tune there before v1 ships.
