# Draft bake-off — result

**Winner: `a-rust-binary` (49/60).** `c-batch-miner` 46, `b-pure-zsh` 42.

| draft | never-blocking | unintrusive | setup | stability | KISS | fulfils ask | total |
|---|---|---|---|---|---|---|---|
| a-rust-binary | 10 | 8 | 9 | 6 | 9 | 7 | **49** |
| c-batch-miner | 10 | 8 | 6 | 8 | 9 | 5 | **46** |
| b-pure-zsh | 9 | 6 | 7 | 6 | 8 | 6 | **42** |

A won on the top two values: a fork-free `preexec` lookup over `${(@kv)aliases}` (0.047–0.083 ms measured)
and deferred `precmd` delivery that makes prompt corruption structurally impossible. C matched the cost but
shipped a six-hourly digest instead of the live nudge; B's detached miner printed over the prompt and its
segment splitter truncated any command containing a quoted pipe. `SPEC.md` starts from A, fixes its three
verified defects (world-readable log, unquoted `${(kv)aliases}`, `${+reswords[…]}`), and grafts C's one-time
`$HISTFILE` seed, golden/budget CI tests and registry provenance, plus B's `_AA_EQUIV` semantic map.
