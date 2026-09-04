---
date: 2026-09-04
reviewer: kiss-subagent
subject: SPEC.md (auto-alias) reviewed against docs/scoping.md
status: review
---

# KISS review — auto-alias SPEC.md

Everything below marked **verified** was reproduced on this machine (zsh 5.9.2,
aarch64-apple-darwin24.6.0) by extracting §2's snippet with `sed -n '38,130p' SPEC.md` into a temp
`HOME`/`ZDOTDIR` and running it. Everything marked **by reading** is an inconsistency inside the
document itself. No Rust exists in the repo, so every rule-2 claim is unverifiable in principle
today — see finding 21.

## What holds up

Credit where the spec earns it, because most of it does.

- **Rule 1 works, live.** T1, T2, T3, T5, T6, T7 all reproduce exactly as §15 claims. `git status
  --short` → `auto-alias: gs is 'git status' — 'gs --short' would have done it.`; `gs` and `echo hi`
  are silent; `cd /tmp` with `equiv cd|c` fires; `alias empty=''` does not poison the table; state is
  `drwx------`/`-rw-------`; `__aa_free` correctly rejects `if`, `do`, `ls`, `g`, `empty` and accepts
  `zzq`. The snippet is 93 lines and passes `zsh -n`, as stated.
- **The hot-path numbers reproduce.** 2000 iterations each, real interactive shell:

  | operation | spec | measured here |
  |---|---|---|
  | `__aa_preexec`, match | 0.047 ms | **0.040 ms** (79 ms / 2000) |
  | `__aa_preexec`, no match + log append | 0.051–0.069 ms | **0.069 ms** (139 ms / 2000) |
  | `__aa_preexec`, long pipeline | 0.083 ms | **0.117 ms** (234 ms / 2000, 22 words) |
  | `__aa_precmd`, idle | 0.005 ms | **0.010 ms** (19 ms / 2000) |

  Same order of magnitude throughout; §8 is honest. (My first run showed 0.79 ms/call — that was my
  harness using `zsh -f -c`, which is non-interactive, so line 2's `[[ -o interactive ]] || return 0`
  returned before defining anything and I was timing 2000 command-not-found lookups. The guard is
  correct and doing its job.)
- **The fork-free discipline is real.** `zf_mkdir`/`zf_chmod`/`zf_rm` are builtins, `$(<file)` in
  `__aa_precmd` is zsh's no-fork read, and the reverse lookup is a hash. Zero forks per command on
  the common path is true as written.
- **D7 (defer to the next `precmd`) is the right call** and is the single best decision in the
  document — it deletes the whole `zle -F`/async-runtime branch. Finding 1 is a bug in the
  implementation of that decision, not in the decision.
- **The three draft-A defects fixed in §2** (quoted `${(@kv)}`, `reswords` as an array, explicit
  0700/0600) are all real and all correctly fixed; I reproduced T5 and T7 both ways.

## Blocker

### 1. "Prompt corruption is structurally impossible" is false — `analyze`'s stdout is attached

§12 says the detached `analyze` "has both streams closed"; §8 calls the budget safe because of it.
The snippet's only call site is:

```zsh
(( ++_aa_n % AUTO_ALIAS_EVERY == 0 )) && { auto-alias analyze &! } 2>/dev/null
```

Only stderr is redirected. **Verified**: with a stub `auto-alias` on `$PATH` that writes to both
streams, `STDOUT-LEAK-FROM-ANALYZE` lands on the terminal 0.3 s later, unattached to any prompt —
exactly the corruption D7 was chosen to make impossible. §8's "verified silent with nothing on
`$PATH`" tested only the one case where the binary produces no output at all.

Fix (one character class, both verified silent here):

```zsh
(( ++_aa_n % AUTO_ALIAS_EVERY == 0 )) && { auto-alias analyze &! } >/dev/null 2>&1
```

Add an acceptance test with a stub binary that writes to stdout; the current T-suite cannot catch
this because it never puts a binary on `$PATH`.

## Major

### 2. `zmodload` degradation is claimed but not implemented, and `__aa_free` fails open

§8: "`zmodload` failure — the snippet aborts before installing a hook." Nothing in the snippet
aborts; there is no `|| return`, no `set -e`. **Verified**: with `zsh/files` replaced by a
nonexistent module, both hooks were still installed.

Worse, the `zsh/parameter` case fails in the unsafe direction. **Verified**: without that module,
`__aa_free` reports `if`, `do` and `ls` as **FREE** — `${+builtins[...]}`, `${+commands[...]}` and
`${reswords[(Ie)...]}` all evaluate to 0 against absent parameters. The collision check that §6
leans on ("the **shell** picks the first free one at print time") silently becomes a no-op, and the
tool proposes `alias if=...`.

Fix: implement the claimed abort, and make `__aa_free` fail closed.

```zsh
zmodload -F zsh/parameter p:aliases p:galiases p:functions p:builtins p:commands p:reswords || return 0
zmodload -F zsh/files b:zf_mkdir b:zf_chmod b:zf_rm || return 0
```

### 3. An unwritable or full state dir prints an error on every single command

The log append has no redirection. **Verified**: with the state dir mode 0500,
`__aa_preexec:7: permission denied: .../log` prints on *every* command, forever, with no recovery
path. A full disk, a read-only `$HOME`, or a state dir synced by a tool that clobbers permissions
turns the shell into a nag loop. This is the clearest violation of "unintrusive" in the document,
and the failure is permanent rather than transient.

Fix: `... >> $AUTO_ALIAS_STATE/log 2>/dev/null || _aa_off_log=1`, and skip the append when set —
one shell variable, self-healing on the next shell.

### 4. "Rule 2 never re-proposes what rule 1 covers" is false for prefix matches

§6 rests this on `[[ -z ${_aa_rev[$f[2]]} ]]` in `__aa_precmd`. That is a single whole-body lookup;
rule 1 does a **word-prefix walk**. So any body whose *first word* is aliased passes revalidation.

**Verified**: with `g='git '` defined, a `pending` fixture proposing `gwl` for `git worktree list`
prints. This is not a corner case — `git worktree list` is the third most frequent repeat in the
real history (47 occurrences; `git …` is 1108 lines total). The user gets told "`g worktree list`
would have done it" and then, separately, "add `gwl`".

Fix: factor the prefix walk out of `__aa_preexec` into `__aa_lookup` and call it from both places.
This is the one abstraction the spec *should* introduce and doesn't — it has two call sites.

### 5. `equiv` serves the single largest signal but has no discovery path and no documented format

The brief's #1 evidence row is 789 `cd …` lines. §5 step 3 and D4 both hand that entirely to
`_aa_equiv`, which is populated **only** by hand-written `equiv cd|c` lines in a config file whose
format appears once, mid-sentence, at line 167. Nothing in §6's groups A/B/C detects an equivalence;
there is no `auto-alias equiv` subcommand in §10 or §11; `analyze` never writes one.

Out of the box, on a fresh install, auto-alias is silent on the largest thing the brief asked it to
notice. Note also that `c='z '` is excluded from `_aa_rev` by `[[ -n $b && $#n -lt $#b ]]` (1 < 1 is
false — **verified**, the built table contained only `git status`, `git`, `mise`), so even typing
`z /tmp` produces nothing.

Either ship a starter `config` with the equivalences derivable from the user's own aliases at
`init` time, or make `doctor` print the suggestion, or state plainly in §11 that the 789-line signal
needs manual setup. Right now §5 implies coverage the code does not deliver unaided.

### 6. "Always current — nothing imported, nothing synced, no drift" is false

§4's central argument for dissolving constraint 6. `${(@kv)aliases}` is live, but `_aa_rev` is not —
it is built **once**, on the first `precmd`, and never again.

**Verified**: define an alias after the first prompt, and `_aa_rev` never sees it
(`${+aliases[longcmd]}` = 1, `${+_aa_rev[...]}` = 0), so rule 1 stays silent for the rest of the
session. This bites the tool's own M5 workflow: run `auto-alias add hcf '...'`, source it, and rule 1
still does not know about `hcf` until a new shell.

Either rebuild the table when `$#aliases` changes (one integer compare in `precmd`, ~0.01 ms) or
soften §4 to "current as of shell start". Do not leave the stronger claim standing.

### 7. The uninstall line breaks the operator's symlinked `.zshrc` — the exact thing it claims to avoid

```sh
# uninstall: perl -ni -e 'print unless /auto-alias init zsh/' ~/.zshrc   (sed -i breaks the symlink)
```

**Verified**: `perl -ni` replaces the symlink with a regular file exactly as `sed -i` does. After
running it on a symlink, `[ -L link ]` is false and the git-tracked target is **unmodified** — the
user's dotfile is now silently detached from its repo with the line still present in the tracked
copy. The scoping brief records `~/.zshrc` is a symlink into a git repo, so this is the default case.

Fix: `perl -i -e ... "$(readlink -f ~/.zshrc)"`, or just tell the user to delete the line.

### 8. Delete the timestamped log subsystem

This is the largest KISS finding. Per D3, the log exists for exactly one thing: a time dimension
`$HISTFILE` lacks, which is used for exactly one threshold — "≥ 5 in 30 d on ≥ 2 distinct days"
instead of the seed's "≥ 20 lifetime".

What that one threshold costs:

- the **only** I/O in the hot path (0.040 → 0.069 ms, a 70% increase on the common path);
- `log.rs`, tail-read, rotation at 2 MB, `log --purge`;
- a second full copy of the user's shell history on disk, and with it the whole §12 secrets
  paragraph, the 0700/0600 assertions, T6, and the `doctor` mode check;
- the secret filter, reimplemented in two languages (finding 14);
- the "two corpora and sums them" logic in `group.rs` and the "never re-read" seed invariant;
- findings 1 and 3 above, both of which only exist because of the log.

What "≥ 20 lifetime" alone gets you, measured against the operator's real 26 816-line history
(normalized, ASCII-filtered, body ≥ 12 chars): **23 candidates**, including
`echo "'$(pwd)'" | pbcopy` (76), `fly ssh console -a toad-icy-tide-7421` (68), `git worktree list`
(47), `git-go-prune` (42), `hubspot-conversations-fetch` (27). That is more proposals than the tool
will ever surface — §7 shows one at a time with a 14-day suppression.

Cut the log for v1. `analyze` reads `$HISTFILE` (tracking a byte offset so it is incremental) and
ranks on lifetime count. That deletes `log.rs`, most of `seed.rs`, the two-corpus sum, the hot-path
write, the secret filter, `log --purge`, rotation, and the privacy risk. Reintroduce the log in v2
if the 30-day window turns out to matter — the spec's own §12 already flags the thresholds as
uncalibrated, so buying this much machinery for an uncalibrated threshold is premature.

### 9. Cut proposal groups B and C from v1

Group A alone is well-evidenced. B and C are not.

**Group B (varying tail → function)**, threshold "≥ 5 occurrences with ≥ 3 distinct tails". Its
motivating example is `claude --teleport <id>`. Measured on the real history: **4 occurrences, 1
distinct tail**. It fails both halves of its own threshold. Group B fires **zero times** on the
history that justifies it.

**Group C (chained)**, threshold ≥ 3. Its motivating example
(`command find … | sort -r | fzf`) occurs exactly 3 times — at threshold. The 15 real bodies that
clear ≥ 3 are dominated by things that must not become aliases:

```
  18 pwd | pbcopy
  15 fswatch -o soilytix-document.typ | while read; do typst c eu-residency-zdr-brief.typ; done
   5 | jq .
   4 | select(. != null)\
   4 | if (.params.observations | type) == "array"\
   4 cd "/Users/mfr/b2/.../kws-sow-source" && typst compile --font-path fonts "kws-spinach-sow.typ"
```

Three of those are **fragments of multi-line history entries**, not commands, and would be proposed
as aliases. Several others are single-project absolute paths. §6's naming rule for C ("first
significant token of each segment") produces nonsense on the `fswatch … while read; do … done`
shape.

B and C are roughly two thirds of `group.rs`, `name.rs` and `render.rs` — three grouping strategies,
three naming strategies, two output shapes (`alias` vs function), plus the "function if the body
contains `'`" special case. Ship A. Add B when the log (or `--dry-run` over history) shows a
prefix that actually clears a threshold; add C when a chained command appears that is not
path-specific.

## Minor

### 10. `analyze.lock` is deletable and introduces a stale-lock failure mode

§8 has `analyze` hold `state/analyze.lock` via `O_EXCL` "so overlapping spawns exit at once". But
§12 already guarantees the only thing that matters: `pending` is replaced by `rename(2)`, which is
atomic. Two concurrent analyzes produce last-writer-wins, not corruption. The lock buys only wasted
background CPU.

It costs a permanent silent failure: nothing in the spec removes a stale lock. If `analyze` is
SIGKILLed, the machine sleeps mid-run, or the 2 s self-abort path misses the cleanup, the lock file
persists and rule 2 dies **forever** — and because the process is detached with (per finding 1, it
should be) both streams closed, the user is never told. `doctor` does not check it.

Delete the lock. If you keep it, make it a pid-file that a newer process can steal after a timeout,
and have `doctor` report it.

### 11. The p99 budget is arithmetically wrong

§8: "Budget: **0.2 ms per prompt, p99**; forks per command on the common path: **0**." One prompt in
50 — 2% — spawns `analyze`. **Measured**: 0.43 ms per detached `&!` spawn (85 ms / 200). The p99
prompt is therefore ~0.5 ms, over budget by 2.5×. The "common path" qualifier is honest, but the
budget it sits next to is stated as p99.

Say p95 = 0.2 ms and p99 = 0.7 ms, and have T8 assert both. This matters because §10 makes
`mise run bench` a CI gate — a gate on a percentile that the design deliberately violates will
either be written to exclude the fork (and prove nothing) or flake.

### 12. Four overlapping suppression mechanisms

`_aa_seen` (3600 s, session-local) + `shown` (14 days) + `mute <name>` (permanent) + "`analyze`
refuses to overwrite an existing `pending`". Four states to reason about for one question: should
this message print?

`mute` is the redundant one. `shown` is already a plain append-only file of `name<TAB>body`; muting
is "append a line to it", which a user can do with `echo`. It also has no inverse — §10 lists no
`unmute`, so `mute` is a one-way door in a v1 whose thresholds §12 admits are uncalibrated.

Drop `mute` from v1 and document the `shown` file. Three mechanisms is still one too many, but the
remaining three each have a distinct job.

### 13. `list` is in v1 scope but is never defined

§10 lists it in the dispatch, §11 puts it under "**In:**", §14 never schedules it in any milestone
(M1–M6 cover `init`, `doctor`, `analyze`, `add`, `mute`, but `list` appears only in M5's title).
Nowhere does the spec say what it lists — the registry? proposals? the reverse table? Either define
it in one sentence or cut it.

### 14. The secret filter is specified three times in two languages, with no test

§12: "the seed pass and `log.rs` reapply the filter", on top of the zsh `case` glob in
`__aa_preexec`. Three copies of the same nine-token list that must stay in sync, across a language
boundary, with no acceptance test asserting they agree (§15 has no T for secrets at all).

`log.rs`'s copy is pure redundancy — by construction every line in the log already passed the
preexec filter. Delete it. If finding 8 is taken, only the `$HISTFILE` reader needs a filter and the
zsh copy disappears too, leaving exactly one.

### 15. "hubspot-conversations-fetch 42×" is a substring count, cited for a rule that counts exact repeats

§6 says the seed means "day one already sees `hubspot-conversations-fetch` 42× and
`codex-session-fetch` 9×". Those are `grep -c` counts (**verified**: 42 and 9). Group A counts
*identical normalized lines*, where the real figures are **27** and **8**.

Both still clear the ≥ 20 / ≥ 5 thresholds, so nothing breaks — but a spec that opens §8 with
"Measured today… These replace draft A's figures, which I could not reproduce exactly" should not
then cite a number measured by a different rule than the one it illustrates. Fix the two numbers.

### 16. `minsave` names two different thresholds

`__aa_preexec` hardcodes `(( $#raw - $#cand >= 2 ))` for rule 1. §4 says `config` holds
`minsave = 8`, used by rule 2 (§6's table: "saving ≥ 8"). Same concept, two values, one hardcoded in
zsh and unreachable from the config the user is told to edit.

Either name them `minsave_match` / `minsave_propose`, or drop `minsave` from `config` since rule 2's
thresholds are the binary's business anyway.

### 17. `config` is a bespoke format with two parsers — and the shell's half is deletable

`config` holds five keys in three syntaxes (`repeats = 5`, `window = 30d`, `equiv cd|c`,
`mute …`). The shell parses only `equiv`; Rust parses the rest. That is a hand-rolled config
language with two independent readers and no shared grammar, in a spec whose value order puts KISS
above features.

The shell's parser (snippet lines 67–71, plus the `-r` test) is five lines that can be deleted
outright: `aliases.zsh` is **already sourced executable zsh**, so an equivalence is just
`_aa_equiv[cd]=c` written there by `auto-alias add`. That removes the only file parsing from the
snippet and leaves `config` with a single reader.

## Nit

### 18. `__aa_precmd` loops over a file §7 guarantees has one line

§7: "only the top one is written to `pending`". `__aa_precmd` then iterates `${(f)"$(<pending)"}`
with a `break`. Generality for a case the design forbids. A single read plus one split is two lines
shorter and says what is true.

### 19. The shellcheck/shfmt exclusion may be unnecessary

§10 states `shell/init.zsh` "**must** be excluded from the existing `shellcheck` and `shfmt` hooks"
and calls the loss "accepted knowingly". Both hooks use `types: [shell]`, and `identify` tags `.zsh`
files as `zsh`, not `shell` — so they very likely never match in the first place. Worth 30 seconds
with `identify-cli shell/init.zsh` before writing an exclude, a paragraph of rationale, and an
accepted-loss note into the spec.

### 20. Uninstall leaves aliases in a file nothing sources

```sh
cat ~/.config/auto-alias/aliases.zsh >> ~/.zshrc  # keep what it created, if wanted
```

This appends provenance comments and possibly a function body into `.zshrc` after the `eval` line
was removed. Fine, but it is the third `.zshrc`-mutating command in a five-line uninstall block for
a tool whose §11 non-goals include "automatic editing of `.zshrc`". Point at the file and let the
user decide.

## Does it deliver the ask?

**Rule 1 (match): yes, and it is genuinely good.** Verified working, fast, silent when it should be,
correct on the empty-alias and reserved-word edge cases. Caveat: findings 5 and 6 mean it covers
less of the real history than §5 implies.

**Rule 2 (propose): unverified in principle.** No Rust exists (§10 says so). The one ✓ in §15 that
touches rule 2 is T4, which feeds a **hand-written three-field fixture** to `__aa_precmd` — it tests
the delivery half and nothing about grouping, thresholds, naming or collision-avoidance. So the ✓
marks are honest per-test but collectively read as more coverage than they are. Findings 4, 8 and 9
all land on the untested half.

**Functional one-liner: yes for rule 2, informational for rule 1.** §7's proposal lines are
paste-and-run (`auto-alias add hcf '…'`). Rule 1's line is advisory, which is correct — there is
nothing to add when the alias already exists.

**Never-blocking by construction: not yet.** The hot path genuinely is fork-free and measured, which
is the hard part and it is done. But three of the guarantees are asserted rather than built:
the detached spawn's stdout is attached (1), the `zmodload` abort does not exist and `__aa_free`
fails open (2), and a write failure nags forever (3). Each is a one-to-three-line fix, and each is
currently held up by prose rather than by code.

## Suggested v1, if you want the smallest thing that carries the evidence

1. Fix 1, 2, 3, 4, 6, 7 — all small, all in the snippet or one line of prose.
2. Ship M1 as specified. It is excellent and carries the ~1900-hit signal alone.
3. Then group A only, ranked on lifetime count over `$HISTFILE`, no log, no seed file, no lock
   (findings 8, 9, 10).
4. Subcommands: `init`, `analyze`, `add`, `doctor`. Drop `list` and `mute` (13, 12).
5. Give `equiv` a discovery path or say plainly that it needs manual setup (5).

That deletes `log.rs`, most of `seed.rs`, two thirds of `group.rs`/`name.rs`/`render.rs`, the lock,
two subcommands, two of three secret-filter copies, and the shell's config parser — and, by my
reading of the evidence, loses no proposal the operator's real history would have produced.
