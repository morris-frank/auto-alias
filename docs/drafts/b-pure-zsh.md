---
date: 2026-09-04
status: draft
angle: B — zero compile (pure zsh plugin)
---

# auto-alias — Angle B: pure zsh, no binary

## 1. Summary

One sourced zsh file, no compiler, no daemon, no fork on the hot path. Rule 1 (match) runs in-process in
`preexec` against a reverse table built from zsh's own `$aliases` parameter — measured **0.08 ms per command**,
12× under budget. Rule 2 (propose) runs in a detached subshell at most every 15 min over the tool's own
timestamped log, and drops one-liners into a pending file that `precmd` prints. Registry is a plain zsh file
the plugin sources; externally defined aliases are never imported — the table is read live, so all 37 in
`.zshrc` work on day one. Fuzzy matching, interactive accept and bash-on-remote are cut from v1.
The honest cost is stated in §12: zsh has no linter, and arithmetic array subscripts will execute history text.

## 2. Architecture

Three files, one process. No IPC, no lock, no state machine.

```
~/.local/share/auto-alias/auto-alias.zsh   the plugin (sourced from .zshrc)
~/.config/auto-alias/{aliases,config}.zsh  registry + settings (sourced by the plugin)
~/.local/share/auto-alias/commands.log     append-only, "<epoch>\t<typed line>"
~/.local/share/auto-alias/pending          messages waiting for the next prompt
~/.local/share/auto-alias/last-mine        mtime = throttle stamp
```

Data flow: `preexec` appends the typed line to the log (0.015 ms) and does the rule-1 lookup (0.02 ms/segment),
printing at most one line. `precmd` prints and truncates `pending`, then — if `last-mine` is older than 15 min —
touches the stamp and forks the miner with `&!` (detached, no job-control noise). The miner appends proposals to
`pending`, which the *next* `precmd` prints. Nothing writes to the terminal from the background.

There is no `auto-alias init zsh`: `eval "$(binary init zsh)"` exists in zoxide/mise because a binary must run
anyway, whereas here it would only add a fork per shell start. `source` is the equivalent and is cheaper. The
`auto-alias` command is a zsh function the plugin defines, so `auto-alias add …` also forks nothing.

The core, verified with `zsh -n` and exercised in a real interactive zsh (§8):

```zsh
# auto-alias core — pure zsh, no binary, no fork on the hot path.
(( ${+_AA_LOADED} )) && return 0
typeset -g _AA_LOADED=1
zmodload zsh/parameter zsh/datetime zsh/stat 2>/dev/null || return 0
autoload -Uz add-zsh-hook

typeset -g  _AA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/auto-alias
typeset -g  _AA_CFG=${XDG_CONFIG_HOME:-$HOME/.config}/auto-alias
typeset -g  _AA_LOG=$_AA_DIR/commands.log _AA_PEND=$_AA_DIR/pending _AA_STAMP=$_AA_DIR/last-mine
typeset -gA _AA_REV _AA_EQUIV _AA_SEEN
typeset -gi _AA_N=0
[[ -d $_AA_DIR ]] || mkdir -p $_AA_DIR

_aa_reload() {                                   # 0.155 ms for 37 aliases, no fork
  emulate -L zsh -o extendedglob
  local k v
  _AA_REV=()
  for k v in ${(kv)aliases}; do                  # zsh/parameter: the live alias table
    v=${${v##[[:space:]]#}%%[[:space:]]#}        # trailing space in gs='git status ' is load-bearing
    [[ -n $v && $k != $v ]] || continue
    [[ -z ${_AA_REV[$v]} || ${#k} -lt ${#_AA_REV[$v]} ]] && _AA_REV[$v]=$k
  done
  for k v in ${(kv)_AA_EQUIV}; do                # cd -> z, so 'cd x' suggests c='z '
    [[ -n ${_AA_REV[$v]} ]] && _AA_REV[$k]=${_AA_REV[$v]}
  done
  _AA_N=${#aliases}
}

typeset -g _AA_HIT _AA_PRE
_aa_lookup() {                                   # longest aliased prefix, max 4 words
  emulate -L zsh
  local -a w; w=(${(z)1}); _AA_HIT=; _AA_PRE=
  local cand; local -i i n=${#w}
  (( n > 4 )) && n=4
  for (( i = n; i >= 1; i-- )); do
    cand="${(j: :)w[1,i]}"
    [[ -n ${_AA_REV[$cand]} ]] && { _AA_HIT=${_AA_REV[$cand]}; _AA_PRE=$cand; return 0 }
  done
  return 1
}

_aa_say() {   # NO_COLOR or a non-tty stderr drops the escape codes
  [[ -n $NO_COLOR || ! -t 2 ]] && { print -ru2 -- "auto-alias: $1"; return }
  print -ru2 -- $'\e[2mauto-alias:\e[0m '"$1"
}
_aa_preexec() {
  emulate -L zsh -o extendedglob
  print -r -- "$EPOCHSECONDS	$1" >> $_AA_LOG 2>/dev/null
  [[ $1 == "$2" ]] || return 0                   # $2 quoted: unquoted it is a glob pattern
  (( ${#aliases} != _AA_N )) && _aa_reload       # cheap staleness check
  local seg rest; local -i last
  for seg in ${(s:|:)${1//&&/|}}; do             # top-level pipeline/chain split
    seg=${${seg##[[:space:]]#}%%[[:space:]]#}
    _aa_lookup "$seg" || continue
    rest=${seg#$_AA_PRE}
    (( ${#_AA_HIT} + ${#rest} < ${#seg} )) || continue   # must actually be shorter
    last=${_AA_SEEN[$_AA_PRE]:-0}
    (( EPOCHSECONDS - last < ${AUTO_ALIAS_COOLDOWN:-3600} )) && continue
    _AA_SEEN[$_AA_PRE]=$EPOCHSECONDS
    _aa_say "'$_AA_PRE' → $_AA_HIT   (run: $_AA_HIT$rest)"
    return 0                                     # at most one line per command
  done
}

_aa_precmd() {
  emulate -L zsh
  if [[ -s $_AA_PEND ]]; then cat -- $_AA_PEND >&2; : > $_AA_PEND; fi
  local -a st; local -i age=99999
  zstat -A st +mtime -- $_AA_STAMP 2>/dev/null && age=$(( EPOCHSECONDS - st[1] ))
  (( age < ${AUTO_ALIAS_MINE_EVERY:-900} )) && return 0
  : > $_AA_STAMP
  ( _aa_mine ) &!                                # detached; never writes to the tty
}

[[ -r $_AA_CFG/config.zsh  ]] && source $_AA_CFG/config.zsh
[[ -r $_AA_CFG/aliases.zsh ]] && source $_AA_CFG/aliases.zsh
_aa_reload
add-zsh-hook -d preexec _aa_preexec 2>/dev/null  # idempotent re-source (mise pattern)
add-zsh-hook -d precmd  _aa_precmd  2>/dev/null
add-zsh-hook preexec _aa_preexec
add-zsh-hook precmd  _aa_precmd
```

## 3. Install / uninstall

```sh
mkdir -p ~/.local/share/auto-alias
curl -fsSL https://raw.githubusercontent.com/morris-frank/auto-alias/v1/auto-alias.zsh \
  -o ~/.local/share/auto-alias/auto-alias.zsh
printf '\nsource ~/.local/share/auto-alias/auto-alias.zsh\n' >> ~/.zshrc   # must be last
```

Because `~/.zshrc` is a symlink into a git repo, the better variant is to vendor the file into that repo and
source it from there. No network at runtime either way.

```sh
# uninstall
sed -i '' '\|auto-alias.zsh|d' ~/.zshrc
rm -rf ~/.local/share/auto-alias ~/.config/auto-alias
```

The plugin must be sourced **last**, after all aliases are defined. A doctor check enforces it: on the first
`precmd`, if `${#aliases} != _AA_N`, print once `auto-alias: source it at the end of ~/.zshrc` and reload.

## 4. Registry format

`~/.config/auto-alias/aliases.zsh` — plain zsh, sourced, diff-able, chezmoi-safe. `auto-alias add` appends here.

```zsh
# auto-alias registry — managed by `auto-alias add`, safe to hand-edit.
# added 2026-09-02  (was run 16x)
alias hcf='hubspot-conversations-fetch '
# added 2026-09-02  (was run 8x)
alias csf='codex-session-fetch'
# added 2026-09-03  (11x, 10 different tails)
tfm() { terraform -chdir=stacks/prod/meeting-transcripts "$@" }
```

`~/.config/auto-alias/config.zsh`:

```zsh
_AA_EQUIV=( cd z  vi nvim )        # 'cd x' should suggest c='z '
AUTO_ALIAS_MIN_N=5                 # repeats before proposing
AUTO_ALIAS_WINDOW=2000             # log lines considered
AUTO_ALIAS_COOLDOWN=3600           # seconds before repeating the same rule-1 tip
AUTO_ALIAS_MINE_EVERY=900          # seconds between background mining runs
AUTO_ALIAS_MAX_PROPOSALS=3         # per mining run
```

**D6 / constraint 6 — externally defined aliases: read live, never import.** `_aa_reload` iterates
`${(kv)aliases}` from `zsh/parameter`, which is the shell's own table and already contains everything —
the 37 in `.zshrc`, the registry, and anything a plugin defined. Measured **0.155 ms** for 37 entries, once
per shell start, with no fork. Import would create a second source of truth that drifts; parsing `alias -L`
costs a fork and a quoting round-trip (`${(Q)}`) for no gain. `${#aliases}` is a free staleness sentinel, so
an alias defined mid-session is picked up on the next command.

## 5. Rule 1 — match

Exact only. Algorithm, per command, in `preexec`:

1. `[[ $1 == "$2" ]]` — if the typed line differs from the alias-expanded line, an alias already fired; stop.
   (The quotes matter: unquoted, the right side of `==` is a glob pattern.)
2. Split the typed line on top-level `&&` and `|` into segments.
3. Per segment, tokenize with `${(z)}` and try the longest prefix first, from 4 words down to 1, as a key
   into `_AA_REV`. First hit wins.
4. Require `len(alias) + len(rest) < len(segment)`.
5. Require the same prefix not to have been reported in the last 3600 s.
6. Print one line, stop — never two tips for one command.

Verified on this machine: `git status --short` → `gs --short`; `git push origin main` → `gp main`;
`ls -la | git diff` → `gd`; `cd ~/code` → `c ~/code` (via the equivalence map); `mise run typecheck` → `m run
typecheck`; `echo hi` → silent; typing `gs` → silent.

**Fuzzy is not in v1.** In pure zsh, edit distance is an interpreted O(n·m) loop per candidate; against 37
aliases that is milliseconds in `preexec`, which breaks the top-priority value. The useful approximations are
already covered: longest-prefix matching handles "the alias covers the head of what I typed", and `_AA_EQUIV`
handles semantic pairs like `cd`/`z` — which is what the 41 `cd` occurrences actually are, not a spelling
distance. If fuzzy is ever wanted it belongs in the background miner, not the hot path.

## 6. Rule 2 — propose

Runs only in the detached miner. Source: the tool's own log (D3), which has real timestamps and no
`SHARE_HISTORY` interleaving.

- **Normalization**: strip the `<epoch>\t`, trim leading and trailing whitespace. Interior whitespace is *not*
  collapsed — measured, that one extendedglob substitution took the pass from 5 ms to 85 ms for no real gain.
- **Filter**: skip lines shorter than 14 chars; skip any line matching
  `(#i)*(token|secret|password|passwd|api[-_]key|bearer)*`.
- **Window / threshold**: last 2000 log lines, ≥ 5 occurrences. No wall-clock window in v1 — recency is
  positional, which is what a fixed-size tail already gives.
- **Already covered**: run `_aa_lookup` on the candidate; if an alias exists, say nothing. This is why
  `git status` (5× in the seeded test) produced no proposal.
- **Alias vs function**: count exact lines *and* 2-word prefixes separately. A prefix with ≥ 5 occurrences,
  ≥ 3 distinct full lines, and no exact-line winner is a **function** proposal; otherwise an **alias**.
  On the real history this correctly separated `hubspot-conversations-fetch --since 3d` (alias, 16×) from
  `terraform -chdir=stacks/prod/meeting-transcripts …` (function, 11× / 10 tails).
- **Chained pipelines**: proposed whole, as one alias, quoted with `${(q-)}`. No attempt to alias a fragment.
- **Naming**: initials of the hyphen-split basename of word 1, plus the first letter of each following
  non-flag word, capped at 4 chars; then `whence -w -- $cand` in a loop appending `1`…`9` until it returns
  non-zero. Verified: `hubspot-conversations-fetch` → `hcf`, `codex-session-fetch` → `csf`, `mise run
  typecheck` → `mrt`, `git status` → `gs1` (collides, suffixed). The name is a suggestion, editable before use.
- **Cap**: at most 3 proposals per run, highest count first, and a `proposed` ledger file so a declined
  candidate is not offered again for 30 days.

## 7. Output & delivery

Rule 1, synchronous, printed from `preexec` to stderr before the command runs:

```
auto-alias: 'git status' → gs   (run: gs --short)
```

Rule 2, printed from the next `precmd`, above the prompt:

```
auto-alias: ran 16x — auto-alias add 'hubspot-conversations-fetch --since 3d'
auto-alias: 'terraform -chdir=stacks/prod/meeting-transcripts …' ran 11x, 10 different tails — auto-alias add --fn 'terraform -chdir=stacks/prod/meeting-transcripts'
```

`auto-alias add` appends to the registry and defines it in the current shell, so the one-liner is both the
explanation and the action. Rate limiting: rule 1 is one line per command, one per prefix per hour
(`_AA_SEEN`, in-memory, per shell). Rule 2 is ≤ 3 lines per mining run, ≤ 1 run per 15 min per machine
(mtime stamp, shared across shells), each candidate offered at most once per 30 days.
`NO_COLOR` or a non-tty stderr drops the escape codes. Silent when there is nothing to say.

**D7: rule 1 synchronous, rule 2 deferred.** Rule 1 is already computed in the hook — printing it costs one
`print` and lands naturally above the command's own output, the proven zsh-you-should-use behaviour. Rule 2
is produced by a background process and must never touch the tty; writing to a file and having `precmd` cat
it is the boring version of the `zle -F` fd watcher, with no ZLE state to corrupt and no reader to leak.

## 8. Never-blocking guarantee

Synchronous per-prompt work, measured in a real interactive zsh on this machine:

| step | cost |
|---|---|
| `preexec`: log append + miss lookup (3-word command) | **0.052–0.080 ms** (500 iterations = 25.9–40.2 ms) |
| `_aa_reload` at shell start (37 aliases, `$aliases`) | **0.155 ms** |
| `precmd`: empty pending + `zstat` throttle check | < 0.05 ms |
| forks on the common path | **0** |

Budget: **1 ms per command**, enforced by a benchmark in `mise run test` that fails the build above it.
Current headroom is 12–19×. For comparison, one fork+exec of a trivial binary costs 1.17 ms on this machine —
i.e. any binary-backed design starts 14× over what this one spends.

Failure modes are structural rather than handled: no binary to be missing, no network, no daemon, no lock.
If `zmodload` fails the plugin returns before installing any hook; every file write is `2>/dev/null`. The
miner is detached, so a hang is neither waited on nor noticed — worst case the next run past the 15-min stamp
starts a second one, and both are idempotent appenders. A failing `mkdir -p` degrades to rule 1 only.

## 9. Positions on D1–D8

- **D1** Pure zsh, one sourced file. No compiler, no release binaries, no `init` fork, and a 0.08 ms hot path a binary cannot reach.
- **D2** Rule 1 in `preexec` in-process; rule 2 in a detached subshell fired from `precmd`, throttled to 15 min.
- **D3** The tool's own `commands.log` — it has timestamps, `$HISTFILE` here does not, and it is not interleaved by `SHARE_HISTORY`.
- **D4** No fuzzy in v1. Longest-prefix match plus a hand-written `_AA_EQUIV` map covers the observed evidence; edit distance in interpreted zsh cannot meet the hot-path budget.
- **D5** ≥ 5 occurrences in the last 2000 logged commands; name = initials, capped at 4 chars, `whence -w` loop with numeric suffix.
- **D6** Read live from `${(kv)aliases}` every shell start (0.155 ms). Never import, never parse `alias -L`.
- **D7** Rule 1 synchronous in `preexec`; rule 2 deferred to the next `precmd` via a pending file. No `zle -F`.
- **D8** Out of scope. `preexec` does not exist in bash and the whole design is zsh-parameter-native; a bash port would be a rewrite, not a flag.

## 10. Codebase

zsh. Roughly 320 LOC total, no dependencies beyond zsh 5.9 built-in modules
(`zsh/parameter`, `zsh/datetime`, `zsh/stat`).

| file | LOC | contents |
|---|---|---|
| `auto-alias.zsh` | ~110 | the §2 core: table, lookup, hooks, doctor |
| `lib/mine.zsh` | ~60 | `_aa_mine`, sourced lazily by the miner subshell only |
| `lib/cmd.zsh` | ~70 | the `auto-alias` function: `add`, `add --fn`, `reload`, `status`, `prune` |
| `test/run.zsh` | ~60 | harness |
| `test/cases/*.zsh` | ~50 | fixtures: fake `$aliases`, seeded logs, expected output |

Tests run each case in `zsh -f`, seed `_AA_REV` and a fixture log directly, call `_aa_preexec` / `_aa_mine`,
and diff stderr against an expected file — no pty, no sleeps. Two cases are non-negotiable: the hot-path
benchmark asserting < 1 ms, and a hostile-input case that replays 2000 real history lines through the miner
and asserts **zero** bytes on stderr (§12).

`mise.toml` gains `[tasks.test] run = "zsh test/run.zsh"` and a `zsh` tool pin; the existing `check` task and
CI job then cover it unchanged. `prek` gets a local `zsh -n` syntax hook on `*.zsh`. **The existing
`shellcheck` and `shfmt` hooks must be scoped away from `*.zsh`** — neither parses zsh, and shellcheck
already emits a false SC1007 on the correct `_AA_HIT=; _AA_PRE=` line. This is a real loss: the primary
artifact has no static analysis beyond `zsh -n`, which is why the hostile-input test carries the weight.

## 11. v1 scope and non-goals

**In:** rule 1 exact longest-prefix match with the equivalence map; rule 2 alias and function proposals from
the own log; `auto-alias add` / `add --fn` / `reload` / `status`; registry + config files; rate limiting;
`NO_COLOR`; doctor.

**Out:** fuzzy matching (§5); interactive accept via fzf/gum (the one-liner is already the action —
copy-paste, or run `auto-alias add …`); bash/remote; LLM naming; any daemon, socket or SQLite; automatic
editing of `~/.zshrc`; shell-agnostic abstraction; a `--json` interface; alias *usage* statistics; and
`$HISTFILE` as a data source, which buys a cold-start corpus at the price of no timestamps and interleaved
sessions.

## 12. Risks and failure modes

- **Arithmetic subscripts execute history text — the sharpest hazard here.** `(( cnt[$line]++ ))` and even
  `(( cnt[$line] >= 5 ))` re-parse `$line` as an arithmetic subscript. Replaying 2000 real lines from
  `~/.zsh_history` through that form produced 71 stderr errors *and actually invoked `git`*
  (`fatal: cannot change to 'path/to/vault'`), while silently dropping 54 of 735 distinct keys. The safe forms
  are `cnt[$k]=$(( ${cnt[$k]:-0} + 1 ))` and `n=${cnt[$k]}; (( n >= 5 ))`: 0 errors, 735 keys, 5 ms.
  Rule for the codebase: **no `(( ))` may contain an array subscript.** No linter can enforce this, so the
  hostile-input test does.
- **No zsh linter.** shellcheck and shfmt do not parse zsh, so the repo's lint lane will not cover the main
  file. Mitigation in §10; the residual risk is real and should be accepted knowingly.
- **Prompt corruption from async output.** Structurally avoided: the miner writes only to a file, and only
  `precmd` prints. Residual: two miners appending concurrently could interleave a line. Mitigation — the
  miner builds the whole message in memory and does one `print -rn >>` (a single small `O_APPEND` write).
- **`SHARE_HISTORY` interleaving.** Avoided by not reading `$HISTFILE`. The own log is append-only with
  `O_APPEND`; lines under 4 KB are atomic. Cost: an empty corpus on day one, so rule 2 stays silent for the
  first days while rule 1 — which already fires ~80× on the observed history — carries the value.
- **Secrets in the log.** The log records every typed line, including `export FOO_TOKEN=…`. The keyword filter
  (§6) protects *proposals*, not the log. Mitigations: `chmod 0600` at creation, `auto-alias prune`, and an
  `AUTO_ALIAS_NEVER_LOG` regex. Exposure is no worse than `$HISTFILE` in kind, but it is a second copy in a
  directory a user might sync — the README must say so.
- **Alias collisions.** `whence -w` is checked at proposal time, but `auto-alias add` must re-check at write
  time; a name free 20 minutes ago may not be now.
- **Stale reverse table.** `${#aliases}` catches additions and removals but not a redefinition that keeps the
  count. `auto-alias reload` is the escape hatch; a wrong tip is harmless.
- **Multi-shell.** `_AA_SEEN` is per-shell, so ten open terminals can each show the same tip once per hour.
  The 15-min mining stamp is shared via mtime, so rule 2 does not multiply.
- **Wrong tips from textual splitting.** `|` and `&&` inside quotes or a subshell will be split as separators.
  The consequence is a spurious suggestion line, never a wrong execution — the tool prints, it never runs.
