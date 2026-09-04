---
date: 2026-09-04
status: draft spec — angle C (batch miner, no hot path)
---

# auto-alias — draft C: batch miner

## 1. Summary

No per-command hook. One `precmd` function does two `stat`s and, on the first prompt of a shell,
spawns a detached miner if the last mine is older than 6 h. The miner (Rust, zero deps) reads
`$HISTFILE` from a byte cursor, compares against a snapshot of the live shell's `alias -L`, and
leaves at most one line in a pending file that the next prompt prints and truncates.
Measured here: **0.007–0.011 ms per idle prompt**; 2–5 ms on the one prompt per 6 h that mines.
Rule 1 becomes retrospective: "1107 `git …` since the cursor; `g` exists".

## 2. Architecture

Components: one Rust binary (`init`, `mine`, `add`, `dismiss`, `status`); the emitted zsh snippet; four
state files; one registry file.

```
shell start  eval "$(auto-alias init zsh)"  → registers precmd hook, mkdir -p dirs   (1 fork, ~2 ms)
every prompt __auto_alias_precmd            → [[ -s pending ]] ? print to stderr + truncate  (1 stat)
first prompt                                → lastrun < 6 h ? return : dump snapshot,
                                              spawn `auto-alias mine` detached (&!)
out of band  mine  → snapshot + HISTFILE-from-cursor → normalize → rule 1/2 → ledger
                   → write pending.tmp, rename(2) over pending
```

Data flow is one-way: the shell never reads binary output, only a file, and nothing the miner does can
reach the terminal. `auto-alias init zsh` emits (tested with `zsh -ic`, §8):

```zsh
() {
  emulate -L zsh
  [[ -o interactive ]] || return 0
  typeset -g AUTO_ALIAS_STATE=${XDG_STATE_HOME:-$HOME/.local/state}/auto-alias
  typeset -g AUTO_ALIAS_INTERVAL=${AUTO_ALIAS_INTERVAL:-21600}
  zmodload -F zsh/datetime p:EPOCHSECONDS
  zmodload -F zsh/stat b:zstat
  autoload -Uz add-zsh-hook

  __auto_alias_precmd() {
    emulate -L zsh
    local s=$AUTO_ALIAS_STATE
    if [[ -s $s/pending ]]; then
      local m="$(<$s/pending)"; : >| $s/pending; print -ru2 -- $m
    fi
    (( __auto_alias_ran )) && return 0
    typeset -g __auto_alias_ran=1
    local -a t; zstat -A t +mtime $s/lastrun 2>/dev/null
    (( $#t && EPOCHSECONDS - t[1] < AUTO_ALIAS_INTERVAL )) && return 0
    { alias -L; print -rl -- '#fn' ${(ok)functions} '#bi' ${(ok)builtins} \
        '#rw' ${(ok)reswords} '#path' $path } >| $s/snapshot
    ( auto-alias mine >/dev/null 2>&1 & ) &!
    return 0
  }
  add-zsh-hook -d precmd __auto_alias_precmd
  add-zsh-hook precmd __auto_alias_precmd
}
```

`add-zsh-hook -d` first makes re-sourcing idempotent (mise pattern); `&!` disowns, so no job-control
notice reaches the prompt; both streams go to `/dev/null`.

## 3. Install / uninstall

```sh
cargo install auto-alias   # or: brew install morris-frank/tap/auto-alias
echo 'eval "$(auto-alias init zsh)"' >> ~/.zshrc
echo 'source ~/.config/auto-alias/aliases.zsh 2>/dev/null' >> ~/.zshrc   # optional, for `add`
exec zsh
```

`init` also does `mkdir -p ~/.local/state/auto-alias ~/.config/auto-alias` (0700), so the snippet never
creates anything. Uninstall:

```sh
sed -i '' '/auto-alias/d' ~/.zshrc
rm -rf ~/.local/state/auto-alias ~/.config/auto-alias
cargo uninstall auto-alias
```

## 4. Registry format

The registry is real zsh, because the accepted file has to be sourced anyway. One serialization, not two.
`~/.config/auto-alias/aliases.zsh`:

```zsh
# auto-alias registry — managed by `auto-alias add`; safe to hand-edit and to commit.
# fields: added=<iso8601> hits=<count at proposal time> src=<rule>

# added=2026-09-02T09:14:03Z hits=16 src=propose
alias hcf='hubspot-conversations-fetch '

# added=2026-09-02T09:14:03Z hits=4 src=propose
alias ct='claude --teleport '

# added=2026-09-04T07:40:55Z hits=5 src=propose-fn
gsl() { git log --oneline "$1" | head -20 }
```

Machine state lives separately in `~/.local/state/auto-alias/`, not dotfile-managed: `cursor` (byte
offset + 4 KiB head hash), `ledger.tsv`, `lastrun`, `pending`, `snapshot`, `mine.lock`.

**D6 / constraint 6 — externally defined aliases.** Neither import nor sync. The shell that triggers a
mine dumps its live `alias -L` (plus function, builtin, reserved-word names and `$path`) into
`snapshot`, and the miner treats that file as the sole authority on what exists. The 37 aliases in
`.zshrc` are therefore seen exactly as defined, trailing spaces included, with no extra machinery and
no drift, for 0.28 ms of builtin work ≤4×/day. The registry holds only what auto-alias added — it is
never a mirror of the shell.

## 5. Rule 1 — match (exact algorithm)

Input: normalized history lines after the cursor, and the reverse table built from `snapshot`.

1. Build `expansion → shortest alias name` from `alias -L`, trimming trailing whitespace on **both**
   sides (load-bearing: every real alias here is `gs='git status '`). Skip expansions under 3 chars.
2. For each normalized history line `L`: **exact** — `L` is a key, so the user typed the long form of an
   existing alias; **prefix** — the longest key `K` with `L == K` or `L` starting `K + " "`, reported
   only if `alias_of(K) + rest` saves ≥ 3 characters.
3. Aggregate by alias name; report the one alias maximising saving × count, ties by characters saved.

**Fuzzy: not in v1.** The exact + longest-prefix pass already fires on 1107 `git …` and 783 `cd …` lines
(whole 26 802-line file, measured 2026-09-04); fuzzy adds scoring and false positives for no measured
gain. If added later it means token-set match after dropping flags (`git --no-pager status` vs
`git status`) — not edit distance, and never subsequence matching, which is nonsense on shell text.

## 6. Rule 2 — propose

**Normalization.** Lossy byte read — the file contains non-UTF-8 bytes (`sort` and `sed` both fail on it
under UTF-8 locales), so the miner reads `Vec<u8>`. Join backslash-continued lines (265 bare `\` lines
exist today). Strip trailing whitespace, collapse space runs, drop lines under 8 chars and lines
matching the secret filter (§12).

**Window.** No time dimension (`EXTENDED_HISTORY` off, no timestamps). The window is positional: lines
between the stored byte cursor and EOF — "since the last mine", roughly a day. Messages therefore say
"in the last N commands", never "this week". A lifetime pass runs only on `status`.

**Thresholds.** ≥ 5 occurrences in the window, or ≥ 20 lifetime and never yet proposed; ≥ 3 if the line
is ≥ 40 chars. Chained pipelines (`&&`, `||`, `|`) count as one unit at the ≥ 3 threshold.

**Alias vs function.** Group candidates by longest common prefix ending at a token boundary. If every
member is `prefix + suffix` — variation only at the tail — emit an **alias** with a trailing space:
`claude --teleport 01H…`/`01J…` → `alias ct='claude --teleport '`. If the variation is interior, emit a
**function** with positional parameters at the varying slots and `"$@"` at the tail; single-quote the
body, escaping `'` as `'\''`.

**Naming without collisions.** Candidate = lowercase initials of the first ≤3 significant tokens (not
flags, not paths), max 4 chars. Reject if the name is in the snapshot's alias, function, builtin or
reserved-word sets, is an executable on `$path`, or is in the registry or the ledger's dismissed set.
On rejection append the next consonant of the last token, then `2`, `3`; if nothing is free at ≤4
chars, drop the proposal rather than emit a bad name. This is `whence -w` done offline against a
dumped oracle.

## 7. Output & delivery

One line, stderr, no chrome, no color at all in v1 — so `NO_COLOR` holds by construction; if color is
ever added it is gated on `NO_COLOR` unset **and** stderr being a tty.

```
auto-alias  1107x  git …          alias g='git ' already exists           (rule 1)
auto-alias  16x  hubspot-conversations-fetch …   add: alias hcf='hubspot-conversations-fetch '
auto-alias  4x  claude --teleport …              add: alias ct='claude --teleport '
auto-alias  3x  find … | sort -r | fzf           add: alias pywc='command find . -name "*.py" …'
auto-alias  5x  git log --oneline <x> | head -20  add: gsl() { git log --oneline "$1" | head -20 }
```

Long proposals elide with `…` (full text in `auto-alias status`) and end `— or: auto-alias add hcf`.
**Rate limiting** is structural: one mine per `AUTO_ALIAS_INTERVAL` (21600 s), one message per mine; the
ledger suppresses a repeated key for 14 days, permanently after 3 shows or `auto-alias dismiss <key>`.

**D7 — deferred.** Written by a process with no terminal, printed by the *next* `precmd`, synchronously,
before the prompt is drawn. Never same-prompt (a mine takes ~50–200 ms), never a `zle -F` fd watcher.

## 8. Never-blocking guarantee

Per prompt, synchronously, in the common case: one `stat` on `pending`, and after the first prompt one
integer test. Measured on this machine today, `zsh -ic`, `typeset -F SECONDS`:

| path | measured, 3 runs | frequency |
|---|---|---|
| idle prompt | 72–109 ms / 10 000 = **0.007–0.011 ms** | every prompt |
| prompt that delivers a message | **0.2–3.0 ms**, dominated by the tty write | ≤ 1 per 6 h |
| first prompt that mines (zstat + snapshot dump + detached spawn) | **2.1–5.2 ms** | ≤ 4 per day |
| `eval "$(auto-alias init zsh)"` (one fork+exec) | ~1.2–3 ms | shell start |

Budget: **≤ 0.05 ms median prompt, ≤ 6 ms worst prompt**, enforced by a CI test (10 000 idle `precmd`
calls < 250 ms). Binary missing: the pending branch is silent, the spawn fails inside a detached
subshell with both streams on `/dev/null`, `lastrun` stays old so the next shell retries — 0.01 ms per
prompt forever, no error. Binary slow or hung: it holds `mine.lock` (O_EXCL, stale after 5 min) and
nothing waits on it. There is no code path in which the shell blocks on the binary.

## 9. Positions on D1–D8

- **D1** Rust — installed, mise has a rust backend, ~1 MB dependency-free binary, zoxide/mise distribution; `bun --compile`/`deno compile` give 50–90 MB binaries pinning a fast-moving runtime, and their edge (startup) is irrelevant out of band. No Go here.
- **D2** Periodic batch over `$HISTFILE`, spawned from `precmd` on a shell's first prompt when `lastrun` is older than 6 h; no `preexec` hook at all; launchd/cron later, not v1.
- **D3** `$HISTFILE` only — no second copy of the user's commands; a byte cursor replaces timestamps, and SHARE_HISTORY interleaving is a feature rather than a hazard.
- **D4** No fuzzy in v1 — exact + longest-prefix only; §5 defines what fuzzy would mean later.
- **D5** ≥5 window / ≥20 lifetime / ≥3 long-or-chained; names are initials, ≤4 chars, checked against the dumped `whence` oracle, dropped if nothing is free.
- **D6** Copy-paste plus `auto-alias add <name>` appending to `~/.config/auto-alias/aliases.zsh`; no fzf/gum accept UI in v1.
- **D7** Deferred to the next prompt (§7) — never same-prompt, never `zle -F`.
- **D8** Out of scope for v1, but it ports to bash in ~15 lines of `PROMPT_COMMAND` with no `bash-preexec`, precisely because there is no hot path.

## 10. Codebase

Rust 2024 edition, **zero runtime dependencies** (std only: no clap, no serde, no regex — the arg
surface is five subcommands and the formats are TSV and zsh text).

`main.rs` 80 (dispatch) · `init.rs` 60 (snippet as `const &str`, `mkdir -p`) · `snapshot.rs` 90 (reverse
alias table + name oracle) · `history.rs` 110 (cursor, lossy byte read, continuation join,
normalization) · `rules.rs` 200 (rule 1 and 2) · `naming.rs` 80 · `render.rs` 70 (one-liners, NO_COLOR)
· `ledger.rs` 90 (`ledger.tsv`, suppression) · `registry.rs` 70 (append, secret refusal) ·
`shell/init.zsh` 30 (the snippet, kept as a file for the golden test) · `tests/` ~300. **≈880 LOC.**

**Tests.** Unit: normalization, continuation join, cursor reset on rotation, naming collisions, ledger
suppression. Golden: `init zsh` byte-compared to `shell/init.zsh`. Integration (`tests/shell.rs`):
`zsh -n` parses the snippet, and a temp `XDG_STATE_HOME` plus a fixture history (non-UTF-8 bytes, `\`
continuations) under `zsh -ic` asserts that an idle prompt prints nothing, the message appears on
exactly one of two prompts, and the 10 000-prompt budget of §8 holds.

**mise / prek / CI.** Add `rust = "1.98"` to `[tools]`; `[tasks.test]` = `cargo test --locked`;
`[tasks.lint]` = `cargo clippy --all-targets -- -D warnings` and `cargo fmt --check`, wired into
`.pre-commit-config.yaml` as `language: system` hooks so mise stays the only version source. shellcheck
cannot lint zsh, so `shell/init.zsh` is excluded from the shellcheck/shfmt hooks and covered by `zsh -n`
instead. CI unchanged: `prek run --all-files`, then `mise run test`.

## 11. v1 scope and non-goals

In: the snippet, `init`/`mine`/`add`/`dismiss`/`status`; rule 1 exact + prefix; rule 2 recurrence,
long-invocation and pipeline proposals; alias-vs-function selection; collision-checked naming; ledger
suppression; the registry file.

Not in v1: fuzzy matching; interactive accept (fzf/gum); LLM naming; bash/remote; a daemon;
launchd/cron; per-directory aliases; editing or deleting existing aliases; telemetry; a config file —
`AUTO_ALIAS_INTERVAL`, `AUTO_ALIAS_STATE`, `AUTO_ALIAS_DISABLE` and `NO_COLOR` are the whole surface.

**On losing the live nudge.** Never-blocking does *not* by itself force this: the brief measures a zsh
associative-array lookup at 0.0007 ms, so a `preexec` rule-1 nudge would fit the budget too. The real
case for batch is what is *not built*. Rule 2 needs cross-session recurrence, so a live design must
either fork per command (1.17 ms, 1700× the lookup) or keep its own command log — a second copy of
everything typed, with its own rotation, locking and secret exposure. Mining `$HISTFILE` deletes that
component, and SHARE_HISTORY, a hazard for per-session recorders, is exactly the merged log this design
wants. Rate limiting becomes a property, not a feature. And with no `preexec` hook there is nothing to
conflict with other plugins, nothing to regress on upgrade, and a missing binary is indistinguishable
from a working one. What is genuinely lost is immediacy — "you just typed `git status`" is a stronger
cue than a morning digest, and nothing here says otherwise; the mitigation is specificity (a count, a
sample, a paste-ready line). The load-bearing point is that this is a strict subset: adding the live
nudge later is one `preexec` hook over a reverse table the miner already produces, with no change to
§2–§7. Ship the cheap half, measure whether the digest changes behaviour, add the nudge only if not.

## 12. Risks and failure modes

- **Prompt corruption from async output** — structurally impossible: the miner's streams go to
  `/dev/null`, it is disowned with `&!` (no job-control notice), and only `precmd` prints. Residual: a
  message written between a shell's read and its truncate is lost — microsecond window, accepted.
- **SHARE_HISTORY interleaving** — benign for aggregate counting, which is all rule 2 does; appends
  during a mine land past the recorded offset and count next run. The cursor stores a hash of the first
  4 KiB; on mismatch (rotation, `SAVEHIST` trim at 100 000 — currently 26 802) it resets to 0.
- **Alias collisions** — the oracle is a snapshot, so a name that went live after the dump could be
  shadowed. `auto-alias add` re-checks with `whence -w` at insertion and refuses on a hit.
- **Multi-shell** — only one mine runs (`lastrun` mtime plus an `O_EXCL` `mine.lock`, stale after 5 min).
  The message goes to whichever shell prompts first, once — the alternative nags in every terminal.
- **Remote bash** — nothing installed, nothing to break. Out of scope in v1 (D8).
- **Secrets in commands** — the real risk here, since the miner reads the whole history file. Lines
  matching the secret filter (`Authorization`, `--token`, `--password`, `AWS_`, `sk-`, `ghp_`,
  `xox[abp]-`, `=<20+ base64-ish chars>`) are dropped before counting so they cannot reach `pending`;
  state files are 0600 in a 0700 dir; `auto-alias add` refuses a matching expansion without `--force`,
  because the registry is meant to be committed. Residual: a secret inside an otherwise ordinary
  command is undetectable, so `pending` and `status` are sensitive output.
- **Cold start** — with no `lastrun`, the first shell mines all 26 802 lines (~630 KB, well under 100 ms
  in Rust) off the prompt, so the first message arrives on the second prompt.
