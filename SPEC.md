---
date: 2026-09-04
status: final specification (revised after adversarial review — see §16)
supersedes: docs/drafts/{a-rust-binary,b-pure-zsh,c-batch-miner}.md
---

# auto-alias — specification

Value order, binding throughout: **never blocking > unintrusive > simple set-up > stable > KISS codebase > features.**

## 1. Summary

One static Rust binary plus one emitted zsh snippet, zoxide-style. The shell owns the hot path: rule 1 (match) is a pure
in-shell hash lookup over `${(@kv)aliases}` — zero forks and zero I/O per command, measured **0.026–0.067 ms**. The binary is
never on the critical path; spawned once per shell, detached from the first `precmd`, it mines `$HISTFILE` incrementally and
writes one proposal line a later `precmd` prints. No daemon, no async runtime, no crates, no network, no log of its own. No fuzzy matching in v1.

## 2. Architecture

| component | role |
|---|---|
| `auto-alias` (Rust, std only) | `init`, `analyze`, `add`, `doctor` — never in the hot path |
| emitted zsh snippet (83 lines) | reverse alias table, rule 1, deferred printing, name revalidation |
| `$XDG_CONFIG_HOME/auto-alias/aliases.zsh` | managed aliases + `equiv` pairs, sourced by the snippet; dotfile-managed |
| `$XDG_DATA_HOME/auto-alias/{offset,pending,shown}` | machine state, 0700 dir, never synced |

```
preexec ─ in-shell reverse lookup, no fork, no I/O ─▶ _aa_msg
precmd  ─ first of each shell: build table, spawn `analyze` detached ─▶ $HISTFILE from offset ▸ count
        ─ prints _aa_msg, else reads pending, revalidates against the live shell, prints, deletes
```

**What `auto-alias init zsh` emits.** Verbatim, `include_str!`'d from `shell/init.zsh`. Passes `zsh -n` and was run end to end
in a real interactive zsh under a temp `HOME` (§15).

```zsh
# auto-alias 0.1 — zsh integration, emitted by `auto-alias init zsh`. Do not edit.
#
# The whole file is one anonymous function. A bare `return` at the top level of an `eval`
# terminates the *calling* script with no error (verified in M1), so a non-interactive shell
# sourcing a file that carries the install line would silently stop there. Inside a function,
# `return` only leaves the function. All state below is declared -g.
() {
[[ -o interactive ]] || return 0
zmodload -F zsh/datetime p:EPOCHSECONDS || return 0
zmodload -F zsh/parameter p:aliases p:galiases p:functions p:builtins p:commands p:reswords || return 0
zmodload -F zsh/files b:zf_mkdir b:zf_rm || return 0
autoload -Uz add-zsh-hook

typeset -gA _aa_rev _aa_equiv _aa_seen
typeset -g  _aa_msg='' _aa_key='' _aa_name='' _aa_tail='' _aa_dim='' _aa_off=''
typeset -gi _aa_boot=0 _aa_na=-1
: ${AUTO_ALIAS_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/auto-alias}
: ${AUTO_ALIAS_STATE:=${XDG_DATA_HOME:-$HOME/.local/share}/auto-alias}
: ${AUTO_ALIAS_COOLDOWN:=3600}
[[ -z $NO_COLOR && -t 2 ]] && { _aa_dim=$'\e[2m'; _aa_off=$'\e[0m'; }
[[ -d $AUTO_ALIAS_STATE ]] || zf_mkdir -m 0700 -p $AUTO_ALIAS_STATE
[[ -r $AUTO_ALIAS_HOME/aliases.zsh ]] && source $AUTO_ALIAS_HOME/aliases.zsh

__aa_table() {                              # rebuilt whenever $#aliases changes
  emulate -L zsh
  local n b
  _aa_rev=(); _aa_na=$#aliases
  for n b in "${(@kv)aliases}"; do          # quoted: an empty body must not shift the pairs
    b=${(j: :)${(z)b}}                      # trim + collapse; gs='git status ' is load-bearing
    [[ -n $b && $#n -le $#b ]] || continue  # -le, not -lt: c='z ' must survive
    [[ -z ${_aa_rev[$b]} || $#n -lt ${#_aa_rev[$b]} ]] && _aa_rev[$b]=$n
  done
}

__aa_lookup() {                             # longest word-prefix hit -> _aa_name/_aa_key/_aa_tail
  local -a w=(${(z)1})
  local i k
  for (( i = $#w; i > 0; i-- )); do
    k=${(j: :)w[1,i]}
    [[ -n ${_aa_rev[$k]} ]] || continue
    _aa_key=$k _aa_name=${_aa_rev[$k]} _aa_tail=${(j: :)w[i+1,-1]}
    return 0
  done
  return 1
}

__aa_free() {                               # exactly what `whence -w` classifies, no fork
  (( ${+aliases} && ${+builtins} && ${+commands} && ${+reswords} )) || return 1   # fail closed
  [[ $1 == [a-z][a-z0-9_-]* ]] || return 1
  (( ${+aliases[$1]} + ${+galiases[$1]} + ${+functions[$1]} + ${+builtins[$1]} + ${+commands[$1]} )) && return 1
  (( ${reswords[(Ie)$1]} )) && return 1      # reswords is an array: (Ie), not ${+...}
  return 0
}

__aa_preexec() {
  emulate -L zsh
  [[ $1 == "$2" && $1 != ' '* && $1 != *$'\n'* ]] || return 0
  local raw=${(j: :)${(z)1}} cand e
  local -a w=(${(z)raw})
  (( $#w )) || return 0
  e=${_aa_equiv[$w[1]]}
  if [[ -n $e ]] && (( EPOCHSECONDS - ${_aa_seen[$e]:-0} >= AUTO_ALIAS_COOLDOWN )); then
    _aa_seen[$e]=$EPOCHSECONDS
    _aa_msg="auto-alias: $e replaces $w[1] here — '$e ${(j: :)w[2,-1]}'."
    return 0
  fi
  __aa_lookup $raw || return 0
  cand=$_aa_name; [[ -n $_aa_tail ]] && cand="$_aa_name $_aa_tail"
  (( $#raw - $#cand >= 2 )) || return 0
  (( EPOCHSECONDS - ${_aa_seen[$_aa_name]:-0} < AUTO_ALIAS_COOLDOWN )) && return 0
  _aa_seen[$_aa_name]=$EPOCHSECONDS
  _aa_msg="auto-alias: $_aa_name is '$_aa_key' — '$cand' would have done it."
}

__aa_precmd() {
  (( _aa_boot++ )) || { auto-alias analyze </dev/null >/dev/null 2>&1 &! } 2>/dev/null
  (( $#aliases == _aa_na )) || __aa_table
  if [[ -n $_aa_msg ]]; then print -ru2 -- $_aa_dim$_aa_msg$_aa_off; _aa_msg=''; return 0; fi
  [[ -s $AUTO_ALIAS_STATE/pending ]] || return 0
  emulate -L zsh
  local T=$'\t'; local -a f=("${(@ps:$T:)$(<$AUTO_ALIAS_STATE/pending)}")
  zf_rm -f $AUTO_ALIAS_STATE/pending
  (( $#f == 3 )) && __aa_free $f[1] && ! __aa_lookup $f[2] || return 0
  print -ru2 -- $_aa_dim$f[3]$_aa_off
  print -r -- "$f[1]$T$f[2]" >> $AUTO_ALIAS_STATE/shown 2>/dev/null
}

add-zsh-hook -d preexec __aa_preexec; add-zsh-hook preexec __aa_preexec
add-zsh-hook -d precmd  __aa_precmd;  add-zsh-hook precmd  __aa_precmd
}
```

Three draft-A defects survive as comments above: quoted `${(@kv)aliases}` (unquoted, `alias empty=''` shifts every following
pair), `${reswords[(Ie)$1]}` (an array, so `${+reswords[if]}` returns 0 and `if` passed as free), and 0700 creation rather than
umask 022. Review fixes are in §16; the load-bearing ones are the `-le` guard, the shared `__aa_lookup`, the `$#aliases` rebuild
trigger, `|| return 0` on the `zmodload` lines with a fail-closed `__aa_free`, and `</dev/null >/dev/null 2>&1` on the detached
spawn.

## 3. Install / uninstall

```sh
cargo install --locked --git https://github.com/morris-frank/auto-alias   # see §12 on distribution
echo 'eval "$(auto-alias init zsh)"' >> ~/.zshrc
exec zsh && auto-alias doctor        # hook state, table size, offset, 0700 assertion
# uninstall: delete the `auto-alias init zsh` line from ~/.zshrc by hand — it is a symlink into a git repo
#            and `perl -ni` replaces the link with a regular file (verified); `sed -i ''` refuses outright
#            ("in-place editing only works for regular files"), leaving the line in place. Keep
#            ~/.config/auto-alias/aliases.zsh if you want what it created, then
#            rm -rf ~/.local/share/auto-alias && cargo uninstall auto-alias
```

One line in `.zshrc` plus one install step; placement in the rc file is irrelevant (§5). Nothing else is added to `.zshrc` — the
snippet sources the registry itself.

## 4. Registry format

`~/.config/auto-alias/aliases.zsh` — the registry *is* executable zsh, appended to by `auto-alias add`, with provenance in
comments (draft C). The snippet sources it, so there is no second `.zshrc` line to forget, and no config file and no config
parser anywhere: an equivalence pair is a shell assignment in the same file.

```zsh
# auto-alias managed aliases — sourced by the init snippet. Safe to edit, move, or commit.
alias hcf='hubspot-conversations-fetch '   # added=2026-09-04 hits=26 src=repeat
_aa_equiv[cd]=c                            # "typing cd? c would have done it" — a pair, §5 step 3
```

**Constraint 6 — there is no separate registry.** The live alias table *is* the registry: `__aa_table` reads `${(@kv)aliases}`,
a fork-free parameter, so the 36 aliases in `.zshrc` and those in `aliases.zsh` are indistinguishable — nothing imported,
nothing synced (0.151 ms for 47). It is rebuilt on the first prompt and whenever `$#aliases` changes, so an alias added
mid-session — including by `auto-alias add` plus a `source` — is picked up on the next prompt; the compare is one integer test.
`add` writes single-quoted bodies, escaping `'` as `'\''`, refuses a body it cannot round-trip, and runs `zsh -n` on the result:
one unbalanced quote in a sourced file aborts the source and discards every alias after it (draft C's fatal flaw).

## 5. Rule 1 — match

Exact only in v1, entirely in `preexec`, no fork and no filesystem access.

1. Normalize with `${(j: :)${(z)$1}}` — word-split and rejoin, trimming and collapsing on both sides; load bearing, because the
   real aliases carry trailing spaces (`gs='git status '`).
2. `[[ $1 != "$2" ]]` → an alias already expanded → return. Quoted deliberately (unquoted the RHS is a pattern — safe in zsh,
   not in bash). One-directional: `for i in 1 2; do echo $i; done` yields a `$2` with an inserted `;` and no alias in play
   (verified), so this gives false negatives only, never a wrong tip. Lines containing a newline are skipped: `${(z)}` rewrites
   them and no rejoin is a pasteable equivalent.
3. Word 1 in `_aa_equiv` → emit the equivalence message. This covers the 789 `cd …` lines, a *semantics* gap (`c='z '`), not a
   spelling distance (draft B).
4. Else walk word prefixes longest-first via `__aa_lookup`, one 0.0007 ms hash lookup each; first hit wins; suppress unless it
   saves ≥ 2 chars and the name's hourly cooldown has expired.

Verified live: `git status --short`→`gs --short`, `cd /tmp/foo`→`c /tmp/foo`, `mise run typecheck`→`m run typecheck`; `gs` and
`echo hi` print nothing. **Fuzzy is not in v1:** it needs a parser, a scoring function and a false-positive budget, while exact
matching already fires on 1108 `git …` and 789 `cd …` lines of the real history (the brief's 39 and 41 are wrong by ~25×;
re-measured today).

## 6. Rule 2 — propose

`analyze` reads one corpus: `$HISTFILE`, incrementally from the byte offset in `state/offset`, so a second run costs only the
new tail. Read as bytes with lossy UTF-8 (verified: the file is not valid UTF-8), `\`-continued lines joined (536 of them),
normalized as in §5 step 1, §12 secret filter applied first. The file has no timestamps (`EXTENDED_HISTORY` off, verified: zero
`: <epoch>:<dur>;` prefixes in 26 816 lines), so counts and thresholds are lifetime ones.

**Group A, exact repeat** — identical normalized lines, ≥ 20 occurrences, body ≥ 12 chars, saving ≥ 8, emits an alias. One
group, because that is what the evidence supports: 22 bodies clear it on the real 26 816-line history (`echo "'$(pwd)'" |
pbcopy` 75, `fly ssh console -a toad-icy-tide-7421` 66, `git worktree list` 47, `hubspot-conversations-fetch` 26) — far more
than one proposal per 14 days will ever surface. The previous draft's two other groups are cut (§11): the "varying tail" group's
own example, `claude --teleport <id>`, occurs **4 times with 1 distinct tail** (verified), failing both halves of its threshold;
the "chained" group's best real hits are already group-A hits, while its ≥ 3 threshold sweeps in multi-line history fragments
and single-project absolute paths. Ranked by `count × (len(body) − len(name))`; only the top one is written to `pending`, by
`rename(2)`, as `alias n='body '` (trailing space, so the next word is itself alias-expanded — the operator's style).

**Naming.** Initials of the words, splitting on space/`-`/`_`, skipping `-flags` and tokens containing `/`:
`hubspot-conversations-fetch`→`hcf`. The binary emits up to four candidates and cannot check collisions — it cannot see zsh's
tables. The **shell** picks the first free one at print time via `__aa_free`: five `${+…}` lookups plus `${reswords[(Ie)…]}`, no
fork, exactly what `whence -w` classifies, returning "not free" if the parameter tables are unavailable. If nothing is free at ≤
4 characters the proposal is dropped rather than named badly (draft C). The shell also runs the body through `__aa_lookup` and
skips a proposal rule 1 already covers, so `gwl` is never proposed while `g='git '` is loaded (verified).

## 7. Output & delivery

```
auto-alias: gs is 'git status' — 'gs --short' would have done it.       auto-alias: c replaces cd here — 'c /tmp/foo'.
auto-alias: 'hubspot-conversations-fetch' ran 26x. Add it: auto-alias add hcf 'hubspot-conversations-fetch '
```

One line, stderr, dimmed with `\e[2m` only when `NO_COLOR` is unset **and** stderr is a tty; silent whenever there is nothing to
say. The third field of a `pending` line is the whole message, so the binary owns the wording and the shell only validates —
which makes the binary responsible for quoting: `render` builds the complete `auto-alias add` command with the same single-quote
escaping `add` round-trips (`'` → `'\''`), and drops a candidate whose body it cannot escape. One message per prompt, rule 1
before rule 2; per-name cooldown 3600 s, session-local. One live proposal at a time: `analyze` refuses to overwrite an existing
`pending`; a printed proposal is appended to `shown` as `name<TAB>body` and suppressed 14 days — to silence one permanently, add
its line to `shown` by hand.

**D7 — deferred, never async.** The message is computed in `preexec` and printed by the next `precmd` from a shell variable. No
backgrounded process writes to the terminal: that path is a synchronous `print`, and the one detached spawn has all three
streams redirected (§2). No `zle -F`, no fd watcher, no async runtime.

## 8. Never-blocking guarantee

Measured today (zsh 5.9.2, aarch64-apple-darwin24.6.0) against the §2 snippet in a real interactive shell under a temp `HOME`,
47 aliases, 2000 iterations each (200 for the fork rows).

| synchronous work | measured | when |
|---|---|---|
| `__aa_preexec`, match found | **0.026 ms** | every command |
| `__aa_preexec`, no match | **0.028 ms** | every command |
| `__aa_preexec`, 23-word quoted pipeline | **0.067 ms** | every command |
| `__aa_precmd`, nothing pending | **0.006 ms** | every prompt |
| `__aa_table`, 47 aliases | **0.151 ms** | shell start, and on any `$#aliases` change |
| detaching `analyze` with `&!` | **0.39 ms** | once per shell, first prompt |
| one `fork`+`exec` of a trivial binary, for scale | 1.13 ms | never |

Budget, two figures rather than one percentile: **< 0.1 ms of synchronous work on every prompt after the first**, with **zero
forks and zero filesystem access per command**; the first prompt of each shell adds the table build and one detached spawn, **≤
0.6 ms once**. `mise run bench` fails the build above those (CI gate, draft C). Degradation: binary missing — rule 1 never calls
it, and the call site is verified silent with nothing on `$PATH`; binary slow — detached, self-aborts after 2 s, a second copy
overwrites `pending` by atomic `rename(2)`; unwritable state dir — the shell's only write is the `shown` append, redirected to
`/dev/null`, so it stays silent instead of nagging; corrupt `pending` — a line not splitting into three tab fields is skipped
and the file is deleted after every read; `zmodload` failure — each line carries `|| return 0`, so no hook is installed.

## 10. Codebase

Rust 2024, std only. **No dependencies** — `std::{fs,env,process}` covers everything; argument parsing is a `match` on
`args().nth(1)`. `shell/init.zsh` (83, above) · `main.rs` (dispatch, `doctor`) · `paths.rs` (XDG, offset, atomic rename, 0700
creation) · `history.rs` (incremental `$HISTFILE` read, continuation joining, normalization, the single secret filter) ·
`propose.rs` (count, threshold, rank, name, render) · `add.rs`. **Size is an estimate only — roughly 350–450 LOC; no Rust exists
yet.**

**Tests.** `cargo test` on `history`/`propose` against fixtures derived from the real history (checked in, scrubbed, with
non-UTF-8 bytes and `\` continuations) and on the quote round-trip shared by `add` and `render`; a golden test byte-compares
`auto-alias init zsh` against `shell/init.zsh` (draft C); `tests/shell.zsh` pipes commands into `zsh -i` under a temp `HOME` and
asserts on stderr — the §15 harness. **Tooling:** `mise.toml` gains `rust = "1.98"`; tasks `test` (`cargo test --locked && zsh
tests/shell.zsh`), `lint` (`cargo clippy --all-targets -- -D warnings && cargo fmt --check`) and `bench`, with `check` depending
on all three. `prek` gains a local `zsh -n shell/init.zsh` hook (`language: system`, so mise stays the only version source). The
`shellcheck`/`shfmt` hooks are scoped `types: [shell]`, which `identify` does not apply to `.zsh` — confirm with `identify-cli
shell/init.zsh` and add an exclude only if it matches. Static analysis is therefore `zsh -n` plus §15's live-shell tests. CI runs
on `ubuntu-latest` and needs `apt-get install -y zsh`.

## 11. v1 scope and non-goals

**In:** exact match with prefix rewrite and `equiv` pairs; group-A proposals from `$HISTFILE`; `init`, `analyze`, `add`,
`doctor`; one registry file; deferred one-line output; cooldowns. **Out:** fuzzy matching; the tool's own command log (§16, D3);
the "varying tail" and "chained" proposal groups — measured yield on the real history is zero and near-zero respectively (§6),
and they cost two more grouping strategies, two more naming strategies and a second output shape; `list` and `mute` subcommands;
interactive accept (fzf/gum); LLM naming; bash, fish, remote shells; a daemon; network anything; automatic editing of `.zshrc`;
per-directory aliases; editing or deleting existing aliases; TUI; telemetry.

**Stated plainly:** the 789 `cd …` lines — the largest signal in the brief — are reached only through `equiv` pairs, and out of
the box there are none: the tool is silent on them until the user adds `_aa_equiv[cd]=c` to `aliases.zsh`. Deriving pairs needs
semantics the tool lacks; a guessed default list was rejected.

## 12. Risks and failure modes

- **Prompt corruption** — the only writer to the terminal is a synchronous `print` in `precmd`. The detached `analyze` is
  spawned `</dev/null >/dev/null 2>&1 &!` — verified with a stub binary writing to both streams that nothing reaches the
  terminal, and disowned, so no job-control notice either.
- **Reading history** — `analyze` reads `$HISTFILE`, which the user already owns in plaintext; the tool writes no second copy.
  Lines whose lowercase form contains `token`, `secret`, `password`, `passwd`, `apikey`, `api?key`, `bearer`, `credential` or
  `authorization` are dropped before counting — one filter, one implementation, in `history.rs`, tested over the token list. A
  heuristic, not a guarantee: a positional secret (`deploy abc123def`) is counted, though only after 20 identical repeats can
  it surface. State dir 0700, asserted by `doctor`. Nothing stops a user pointing chezmoi at `$XDG_DATA_HOME`; the README must
  say so plainly rather than imply safety.
- **Threshold miscalibration** — 20 lifetime repeats may be too eager or too shy; `analyze --dry-run` prints what it *would*
  propose over the whole real history before anything is surfaced (M2 exists for it).
- **Alias collisions** — checked in the shell at print time, the only place they can be: a Rust child cannot see its parent's
  aliases and functions, so `add` validates name syntax and `$PATH` only and `__aa_free` is authoritative. **Multi-shell** —
  `pending` is replaced by `rename(2)`, so concurrent runs are last-writer-wins, never torn; per-session cooldowns mean one tip
  per terminal. **Registry corruption** — §4.
- **Distribution** — *unverified:* the crate is not published and no tap exists (crates.io returned 403 here, so even the name
  is unconfirmed); v1 ships `cargo install --git`, brew and mise are M5. **Remote bash** — no hooks, no advice. Accepted.

## 13. Decision log — this is also §9, the position on each of D1–D8

| # | decision | why | from |
|---|---|---|---|
| D1 | Rust, one static binary, std only | zoxide's shape; the only compiled toolchain installed (rustc 1.98); bun/deno compile to 50–90 MB | A |
| D2 | Rule 1 in `preexec` (in-shell); rule 2 in a binary detached once per shell | an in-shell lookup is ~1700× cheaper than the cheapest fork, and once-per-shell keeps every prompt fork-free | A |
| D3 | No own log: `analyze` reads `$HISTFILE` incrementally, lifetime counts | the log bought one threshold refinement and cost the only hot-path I/O, a second copy of history on disk, rotation, purging and a duplicated filter (§16) | A + C, revised |
| D4 | No fuzzy matching in v1; exact prefix plus explicit `equiv` pairs | the 789 `cd …` lines are a semantics gap, not a spelling distance | B |
| D5 | ≥ 20 lifetime repeats, group A only; initials-based names, dropped if none free ≤ 4 chars | 22 candidates on the real history is already more than the tool can surface; refusing to emit beats emitting a bad name | A + C, revised |
| D6 | No separate registry: `${(@kv)aliases}` *is* the registry; `auto-alias add` appends to a file the snippet sources | dissolves constraint 6 — no import, no sync, no second `.zshrc` line | A (+ C's flaw) |
| D7 | Deferred to the next `precmd`, printed synchronously from shell state | keeps every terminal write synchronous and in the foreground shell | A |
| D8 | Bash on remotes out of scope; `init bash` prints an explicit "unsupported" | a half-working `DEBUG` trap is worse than nothing | A |

## 14. Implementation plan

Toolchain pins for `mise.toml`: `rust = "1.98"` under `[tools]` (matches the installed Homebrew rustc; the resolved version is
recorded in the committed `mise.lock`). No other tool is added; CI gains `apt-get -y zsh`.

- **M1 — "alias exists", nothing else.** — **built** (`shell/init.zsh`, `src/main.rs`, `tests/shell.zsh`; 18 shell + 3 cargo
  tests green, measured 0.027 ms per command).
  Original plan: `shell/init.zsh` cut to `__aa_table`, `__aa_lookup`, `__aa_preexec` and the `_aa_msg`
  half of `__aa_precmd`, plus `auto-alias init zsh` — a `println!` of an `include_str!`, the whole binary at this point. No
  state dir, no binary call in the hook, no proposals. This alone carries the ~1900-hit rule-1 signal and is shippable.
  Acceptance: T1, T2, T3, T5, T8, T10's shell half.
- **M2 — `analyze --dry-run`.** `history.rs`, `propose.rs`, `paths.rs`, `doctor`; `--dry-run` prints to stdout and writes
  nothing. Where §6's threshold is calibrated against the real history before anything is ever proposed.
- **M3 — proposals live.** `pending`/`shown`, the detached spawn, `__aa_free`, the rule-2 half of `__aa_precmd`. Acceptance: T4,
  T6, T7, T9.
- **M4 — `add`.** Registry append with the quote escaping shared with `render`, `$PATH` collision check, `zsh -n` of the written
  file. Acceptance: T10.
- **M5 — distribution.** Publish the crate, a Homebrew tap, `mise use -g cargo:auto-alias`; README carries §12's history
  paragraph in full.

## 15. Acceptance tests

All run under a temp `HOME`/`ZDOTDIR` whose `.zshrc` defines `g='git '`, `gs='git status '`, `c='z '`, `m='mise '`, `empty=''`,
then sources the snippet, with `_aa_equiv[cd]=c` in `aliases.zsh`. T1–T7 and T9 are `tests/shell.zsh`; T8 is `mise run bench`;
T10 spans `cargo test` and the shell harness. ✓ marks tests run today against the §2 snippet, before any Rust exists.

1. **T1 exact match** ✓ — `printf 'git status --short\nexit\n' | zsh -i 2>&1` contains exactly one line `auto-alias: gs is 'git
   status' — 'gs --short' would have done it.`
2. **T2 silence** ✓ — the same with `gs` (alias already fired) and `echo hi` yields **zero** `auto-alias:` lines.
3. **T3 equivalence** ✓ — `cd /tmp/foo` prints `auto-alias: c replaces cd here — 'c /tmp/foo'.`
4. **T4 delivery + revalidation** ✓ — a three-field `pending` fixture prints once on the next prompt and the file is gone; with
   `hcf` defined it prints nothing and is still gone; a `gwl<TAB>git worktree list` fixture prints nothing while `g='git '` is
   loaded (the prefix-walk case).
5. **T5 table regression** ✓ — with `alias empty=''` loaded, no reverse-table value may be a zsh default alias (`run-help`,
   `which-command`) — the unquoted `${(kv)aliases}` form fails this — **and** `z` must map to `c`, which `-lt` failed. Measured
   table: `z→c git status→gs git→g mise→m`.
6. **T6 permissions** ✓ — after a fresh shell `stat -f '%Sp'` gives `drwx------` on the state dir; `doctor` exits non-zero if it
   differs. **T7 reserved words** ✓ — `__aa_free` returns 1 for `if`, `do`, `ls`, `g`, `empty` and 0 for `zzq`.
8. **T8 budget** ✓ — 2000 `__aa_preexec 'git status --short' 'git status --short'` in **< 120 ms** (measured 53 ms), 2000 idle
   `__aa_precmd` in **< 30 ms** (14 ms), 200 `__aa_table` at 47 aliases in **< 60 ms** (30 ms); the build fails above these.
9. **T9 no leak** ✓ — with a stub `auto-alias` on `$PATH` that sleeps then writes to **both** streams, a shell start plus a
   prompt produces zero bytes on the terminal. Verified for the §2 spawn form; the previous `{ … &! } 2>/dev/null` form fails
   it.
10. **T10 quoting** — bodies containing `'`, `"`, `$(…)`, a tab and a leading `-` survive `add`'s escaping round-trip and render
    correctly in the message (`cargo test`); a multi-line command yields no advice.

### Independent reproduction (main session, after the review pass)

The §2 snippet was extracted with `sed -n '37,119p' SPEC.md`, sourced from a temp `ZDOTDIR`, and driven through a real
interactive zsh. It loaded clean and behaved as specified: `git status` -> `gs`; `git worktree list --porcelain` -> `gwl
--porcelain`; `mise run typecheck` -> `m run typecheck`; `cd /tmp` -> `c replaces cd here` once `_aa_equiv[cd]=c` was present;
silent for `gs`, `echo hello`, and `echo 'a | b'`; a second `git status` inside the cooldown printed nothing.

Timings reproduced within noise of §8 (41 aliases, 3000 iterations): hit 0.0257 ms, miss 0.0291 ms, alias-used 0.0060 ms,
idle `precmd` 0.0076 ms, table build 0.1315 ms. A fork on the same machine costs 1.13 ms, so the whole per-command path is
about 1/30th of a single fork.

Two traps confirmed by hand, both avoided by the current snippet but fatal to the obvious alternatives:

- `EXTENDED_GLOB` is **off** by default, so a `${v##[[:space:]]##}` trim silently no-ops and every lookup misses with no error
  at all. `emulate -L zsh` plus the `${(j: :)${(z)b}}` normalizer sidesteps this; a plugin that hand-rolls glob trimming does
  not. The normalizer was checked byte-exact on quoted pipes, globs and embedded operators.
- A single `$(...)` command substitution anywhere in the hook forks a subshell. In a scratch prototype it alone moved the hot
  path from 0.015 ms to 0.435 ms, a 28x regression. `$(<file)` is the fork-free read form and is what the snippet uses.

### M1 build notes (what the build changed in this spec)

1. **The `[[ -o interactive ]] || return 0` guard was unsafe as written.** A bare `return` at the top level of an `eval`
   terminates the calling script silently and with exit 0. Reproduced: a script that prints, evals the snippet, then prints
   again produced only the first line. §2 now wraps the whole snippet in an anonymous function. M3 inherits the wrapper.
2. **M1's snippet is §2 minus what M1 does not have**: no `__aa_free`, no `AUTO_ALIAS_STATE`, no `pending`/`shown`, no detached
   spawn, and `zmodload zsh/parameter` narrowed to `p:aliases`. `zsh/files` is not loaded at all. Everything else is verbatim.
3. **A lint gate that always passed.** `zsh -n a b` parses only `a` and turns `b` into a positional parameter, so the obvious
   hook form reported success on a file it never read. Proven by planting a syntax error. The hook now loops per file.
4. **Hooks must be routed through `mise exec`.** Git invokes hooks outside the activated environment, where `cargo` resolves to
   whatever rustup has; `rustfmt` and `clippy` were absent there while present under mise.

## 16. Review log

Every blocker and major from the two reviews. Contested zsh claims were re-run before being accepted; where a premise did not
reproduce, that is said.

| # | reviewer | finding | disposition |
|---|---|---|---|
| B1 | kiss, codex | `{ auto-alias analyze &! } 2>/dev/null` leaves stdout and stdin attached; "both streams closed" is false | **fixed** — spawn is `</dev/null >/dev/null 2>&1 &!`; reproduced the leak with a stub binary and the silence after; T9 added |
| B2 | codex | every 50th `preexec` forks synchronously, breaking the 0.2 ms p99 budget | **fixed** — the spawn is out of `preexec` entirely; one detached spawn on the first `precmd` per shell (0.39 ms, once). `AUTO_ALIAS_EVERY` and its counter are gone |
| M1 | kiss | §8's "`zmodload` failure — the snippet aborts" is false, and `__aa_free` then fails open | **fixed** — `|| return 0` on all three `zmodload` lines; `__aa_free` returns 1 when the parameter tables are absent. Note: the reviewer's repro is weaker than claimed — zsh autoloads `reswords`/`commands`, so `if` and `ls` stayed classified in my run — but the claim in §8 was false and fail-closed is one line |
| M2 | kiss | unwritable state dir makes the log append print `permission denied` on every prompt forever | **fixed** — the log is gone (M7); the one remaining shell write, the `shown` append, is `2>/dev/null` |
| M3 | kiss | revalidation is a whole-body lookup, so rule 2 re-proposes what rule 1 covers (`gwl` vs `g='git '`) | **fixed** — prefix walk factored into `__aa_lookup`, called from both hooks; verified the `gwl` fixture now prints nothing. T4 extended |
| M4 | kiss | `equiv` pairs are the only route to the 789-line `cd` signal and nothing populates them; `c='z '` was also excluded from the table by `$#n -lt $#b` | **fixed** — guard is `-le` (verified `z→c` now in the table); pairs are shell assignments in `aliases.zsh`, no config parser; §11 states plainly that the signal needs one manual line |
| M5 | kiss | `_aa_rev` is a one-shot snapshot, contradicting §4's "always current, no drift" | **fixed** — rebuilt whenever `$#aliases` changes, one integer compare per prompt; §4's claim narrowed to match |
| M6 | kiss | uninstall's `perl -ni` breaks a symlinked `.zshrc` exactly as `sed -i` does | **fixed** (reproduced: the link became a regular file and the git-tracked target kept the line) — uninstall now says delete the line by hand |
| M7 | kiss | the timestamped log subsystem buys one threshold refinement and costs the only hot-path I/O, `log.rs`, rotation, `log --purge`, a duplicate secret filter, a second copy of history on disk and two of the findings above | **fixed** — cut. `analyze` reads `$HISTFILE` from a byte offset and ranks on lifetime count; 22 candidates clear ≥ 20 on the real history (verified). D3 rewritten |
| M8 | kiss | proposal groups B and C have zero and near-zero measured yield | **fixed** — group A only. Verified `claude --teleport`: 4 occurrences, 1 distinct tail, so group B could never have fired. Both listed in §11 Out with the numbers |
| M9 | codex | synchronous filesystem work in the hooks is not "never blocking" | **fixed** — `preexec` now touches no file at all; `precmd`'s only steady-state I/O is one `-s` test. §8 restates the budget as measured figures per prompt rather than one p99 number |
| M10 | codex | command reconstruction via `${(z)}` + rejoin is not proven to preserve quoting | **partly fixed** — multi-line lines are now skipped (verified `${(z)}` rewrites them), and T10 adds adversarial cases. Not fully fixed: rule 1's output is advisory text the user reads before pasting, and restricting it to "demonstrably safe token forms" would silently drop most real commands |
| M11 | codex | proposal messages interpolate raw bodies between single quotes | **fixed** — §7 makes `render` build the whole `auto-alias add` command with the same escaping `add` round-trips, and drop a body it cannot escape; shared routine, tested |
| M12 | codex | seed and live log can double-count under `SHARE_HISTORY` | **fixed** — moot, there is one corpus and one offset |
| M13 | codex | `add` cannot re-check with `whence -w`; a Rust child cannot see the parent shell's tables | **fixed** — §12 now says `add` checks name syntax and `$PATH` only; `__aa_free` in the shell is authoritative |
| M14 | codex | hook failure modes unhandled: state errors, `AUTO_ALIAS_EVERY=0` | **fixed** — `AUTO_ALIAS_EVERY` no longer exists (verified `(( x % 0 ))` aborts the hook with `division by zero`); writes redirected; `zmodload` guarded |
| M15 | codex | M1 is not the smallest implementation of "alias exists" | **partly fixed** — M1 loses the log, the config parser, `doctor`, `__aa_free` and every hook state but rule 1; T3 is in M1 since `equiv` is. **Rejected** in one part: M1 keeps the binary, because `init` must emit the snippet and a `println!(include_str!(…))` is smaller than shipping a plugin file and migrating it later |

Minors and nits, all taken: `analyze.lock` deleted (`rename(2)` already gives atomicity and nothing removed a stale one); `list`
and `mute` cut (undefined, and redundant — `shown` is documented instead); one secret filter, not three; counts corrected to
measured exact repeats (26 and 8, not substring counts 42 and 9); `minsave` and the whole `config` file dropped; the `pending`
loop reduced to a single-line read; the shellcheck/shfmt exclusion paragraph reduced to one line.
