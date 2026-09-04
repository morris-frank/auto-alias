# External spec review — OpenAI codex CLI

- **Reviewer:** OpenAI codex CLI, `codex-cli 0.153.2`
- **Date:** 2026-09-04
- **Sandbox:** `read-only` (no file edits permitted)
- **Working dir:** `/Users/mfr/code/morris-frank/auto-alias`

Exact command:

```sh
codex exec -C /Users/mfr/code/morris-frank/auto-alias -s read-only --color never \
  -o <scratch>/last.md "$(cat <scratch>/prompt.txt)"
```

Prompt given to codex:

```text
Read docs/scoping.md and SPEC.md in this repository.

Act as a senior systems engineer who has shipped zsh plugins and small Rust/Go CLIs. Critique SPEC.md against the scoping doc. Focus on:
(a) correctness of the zsh hook, quoting, and async claims;
(b) any violation of the never-blocking-the-prompt requirement;
(c) over-engineering relative to the explicit KISS ask;
(d) missing failure modes;
(e) whether the implementation plan's M1 is truly minimal.

Return findings as a list. For each: severity (blocker | major | minor | nit), section, finding, suggested fix. End with an overall verdict paragraph.

Do not modify any files. Keep the whole response under 120 lines.
```

---

## Raw codex stdout (verbatim)

1. **Severity:** blocker  
   **Section:** §2, §7, §8 — detached analysis  
   **Finding:** `{ auto-alias analyze &! } 2>/dev/null` does not close both streams: stdout and stdin remain attached to the terminal. The claim that background analysis cannot corrupt or interfere with the prompt is therefore false.  
   **Suggested fix:** launch as `auto-alias analyze </dev/null >/dev/null 2>&1 &!`.

2. **Severity:** blocker  
   **Section:** §2, §8 — never-blocking guarantee  
   **Finding:** Every 50th `preexec` synchronously performs process creation before the child detaches. The specification’s own measurement puts that around 1.19 ms, exceeding its 0.2 ms p99 budget. “The binary is never on the critical path” and “zero forks per command” obscure this periodic prompt-path fork.  
   **Suggested fix:** remove automatic spawning from the hook in v1. Analyze on shell startup, explicit invocation, or a separately scheduled batch.

3. **Severity:** major  
   **Section:** §2, §8 — synchronous filesystem work  
   **Finding:** M2 adds a foreground open-and-append on every command. `precmd` also reads, appends to, and deletes state files when proposals exist. Regular-file operations can block on filesystem contention, full disks, permissions, or unusual XDG locations. The design is fast in measurements, but not “never blocking.”  
   **Suggested fix:** define the requirement honestly as a measured latency budget, or keep all filesystem I/O outside hooks and exchange state through preloaded shell memory.

4. **Severity:** major  
   **Section:** §5 — command reconstruction and quoting  
   **Finding:** The implementation lexes and rejoins commands with `${(z)}` and spaces, but the tests cover only simple arguments. The specification does not establish that quotes, redirections, substitutions, glob syntax, escaped whitespace, empty arguments, newlines, and shell operators survive as a pasteable equivalent.  
   **Suggested fix:** either restrict matching to demonstrably safe token forms or add adversarial shell tests proving byte-equivalent semantics for reconstructed suggestions.

5. **Severity:** major  
   **Section:** §6, §7 — “functional” proposals  
   **Finding:** Proposal messages wrap arbitrary bodies in single quotes without specifying display escaping. Group A can contain `'`, tabs, substitutions, or operators; Group C’s “function if the body contains `'`” does not make the displayed `auto-alias add … 'body'` command valid.  
   **Suggested fix:** generate the complete command using zsh-safe quoting, preferably `${(q)}` semantics reproduced and tested by Rust, rather than interpolating raw bodies between quotes.

6. **Severity:** major  
   **Section:** §6 — seed plus live-log counting  
   **Finding:** The two corpora are “summed,” but under `SHARE_HISTORY` the commands already captured in the tool log may also be present when the first history seed is taken. The first batch can therefore be double-counted. Seed entries also lack dates, making mixed seed/live threshold semantics underspecified.  
   **Suggested fix:** snapshot/seed before logging begins, or record a history boundary and explicitly exclude overlap. Keep seed-only and timestamped evidence separate in threshold calculations.

7. **Severity:** major  
   **Section:** §4, §12 — `add` collision validation  
   **Finding:** A Rust child cannot inspect aliases and functions in its parent interactive shell. “`add` re-checks with `whence -w`” is not implementable as stated unless it launches another interactive zsh, whose environment may differ and whose startup has side effects.  
   **Suggested fix:** make the shell wrapper perform the authoritative check and pass approval to the binary, or state that `add` can validate only syntax and executable-name collisions.

8. **Severity:** major  
   **Section:** §12 — missing hook failure modes  
   **Finding:** Redirect failures are not handled. A missing/unwritable state directory, permission change, full disk, or invalid `AUTO_ALIAS_EVERY=0` can emit errors or break arithmetic during `preexec`, violating the unintrusive requirement.  
   **Suggested fix:** validate configuration once, disable logging/analyzing after the first state error, and ensure hook functions always return successfully and silently.

9. **Severity:** minor  
   **Section:** §2 — re-sourcing and live-table claims  
   **Finding:** Hook registration is idempotent, but `_aa_equiv` is not cleared when rebuilding. Removing an equivalence from config and re-evaluating init can leave stale entries. Also, the alias table is captured only at the first prompt, so aliases defined later are not “always current.”  
   **Suggested fix:** clear `_aa_equiv` in `__aa_table`, and either rebuild after registry changes or narrow the freshness claim.

10. **Severity:** minor  
    **Section:** §2, §12 — log record integrity  
    **Finding:** The log format assumes one physical line containing exactly one tab delimiter. Multiline commands and literal tabs can split or corrupt records. The `PIPE_BUF` argument does not prove atomicity for shell redirection, character-count truncation does not guarantee a byte limit, and concurrent log rotation is unspecified.  
    **Suggested fix:** use an unambiguous encoded record format or reject multiline/tab-containing commands; define locking and rotation behavior before M2.

11. **Severity:** minor  
    **Section:** §12 — secret filtering  
    **Finding:** Substring filtering misses common positional secrets, sensitive environment assignments, URLs with credentials, private keys, and tool-specific flags. It can also suppress harmless commands. The disclosure is honest, but logging every command by default remains a material failure mode.  
    **Suggested fix:** make logging explicitly opt-in, or start with conservative allowlisted command shapes and document history-space behavior as only one safeguard.

12. **Severity:** major  
    **Section:** §14 — M1 minimality  
    **Finding:** M1 is not the smallest implementation of “alias exists.” It introduces a Rust binary, `include_str!`, `doctor`, generated shell, configuration/equivalence handling, benchmarking infrastructure, and several hook states before proving the core lookup. T7 references `__aa_free`, which M1 does not need, while equivalence test T3 is deferred despite equivalence apparently being in M1.  
    **Suggested fix:** make M1 a pure-zsh plugin containing only idempotent hook registration, one reverse table, exact-prefix lookup, deferred message printing, and focused shell tests. Add the binary only when batch analysis becomes necessary.

Overall verdict: **not implementation-ready**. The in-shell exact-match idea is strong and appropriately fast, but the specification overstates its async and never-blocking guarantees, leaves quoting and corpus overlap insufficiently defined, and makes M1 much larger than the KISS brief warrants. Ship the pure-zsh rule-1 slice first; treat logging, Rust analysis, and proposals as separately justified later milestones.
