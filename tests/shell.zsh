#!/usr/bin/env zsh
# Acceptance tests for M1 (SPEC.md §15: T1, T2, T3, T5, T8, T10-shell).
# Every case runs in a fresh interactive zsh under a temp ZDOTDIR, so the
# per-alias cooldown never leaks between cases.
emulate -L zsh
set -u

ROOT=${0:A:h:h}
integer PASS=0 FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
mkdir -p $TMP/zdot $TMP/home

print -r -- 'typeset -gA _aa_equiv
_aa_equiv[cd]=c' > $TMP/home/aliases.zsh

print -r -- "export AUTO_ALIAS_HOME=$TMP/home
alias g='git '
alias gs='git status '
alias c='z '
alias m='mise '
alias empty=''
source $ROOT/shell/init.zsh" > $TMP/zdot/.zshrc

# An interactive zsh prints its prompt on the same line as the first output, so
# every extraction below is unanchored and trims whatever precedes the marker.
pick() { grep -a "$1" | sed "s/.*\($1\)/\1/"; }

# Type commands into a fresh interactive shell; return only the advice lines.
run() { printf '%s\nexit\n' "$1" | ZDOTDIR=$TMP/zdot zsh -i 2>&1 | pick 'auto-alias:'; }
# Evaluate zsh source in that same environment (for white-box checks).
evalin() { printf '%s\nexit\n' "$1" | ZDOTDIR=$TMP/zdot zsh -i 2>&1; }

ok() { print -r -- "  ok   $1"; (( ++PASS )); return 0; }
bad() {
	print -r -- "  FAIL $1"
	print -r -- "       want: $2"
	print -r -- "       got : $3"
	(( ++FAIL ))
	return 0
}
# Literal comparison: the right-hand side is quoted so zsh does not treat it as a pattern.
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi }

print -r -- "T1 exact match with tail"
eq "git status --short -> gs --short" \
	"auto-alias: gs is 'git status' — 'gs --short' would have done it." \
	"$(run 'git status --short')"
eq "bare long form -> bare alias" \
	"auto-alias: gs is 'git status' — 'gs' would have done it." \
	"$(run 'git status')"

print -r -- "T2 silence"
eq "using the alias itself is silent" "" "$(run 'gs')"
eq "unrelated command is silent" "" "$(run 'echo hi')"
eq "empty-bodied alias never matches" "" "$(run 'empty')"

print -r -- "T3 equivalence pair"
eq "cd /tmp/foo -> c" \
	"auto-alias: c replaces cd here — 'c /tmp/foo'." \
	"$(run 'cd /tmp/foo')"
eq "cooldown suppresses the repeat" \
	"auto-alias: c replaces cd here — 'c /tmp/foo'." \
	"$(run 'cd /tmp/foo
cd /tmp/bar')"

print -r -- "T5 reverse-table regression"
tbl=$(evalin '__aa_table; for k in ${(ko)_aa_rev}; do print -r -- "TBL <$k>=<$_aa_rev[$k]>"; done' | pick 'TBL ')
for want in '<z>=<c>' '<git status>=<gs>' '<git>=<g>' '<mise>=<m>'; do
	if [[ $tbl == *"$want"* ]]; then ok "table has $want"; else bad "table has $want" "$want" "$tbl"; fi
done
if [[ $tbl == *run-help* || $tbl == *which-command* ]]; then
	bad "no zsh default alias in the table" "none" "$tbl"
else
	ok "no zsh default alias in the table"
fi

print -r -- "T10-shell quoting and multi-line"
eq "quoted pipe is left alone" "" "$(run "echo 'a | b'")"
eq "leading space opts out" "" "$(run ' git status --short')"
print -r -- '__aa_preexec "git
status" "git
status"
print -r -- "MSG=<$_aa_msg>"' > $TMP/multiline.zsh
eq "multi-line command yields no advice" "MSG=<>" \
	"$(evalin "source $TMP/multiline.zsh" | pick 'MSG=')"

print -r -- "T8 synchronous budget"
print -r -- 'for i in {1..43}; do alias zz$i="cmd$i --flag --other"; done
__aa_table
typeset -F SECONDS
s=$SECONDS; for i in {1..2000}; do __aa_preexec "git status --short" "git status --short"; _aa_seen=(); done
printf "B preexec %.1f\n" $(( (SECONDS-s)*1000 ))
s=$SECONDS; for i in {1..2000}; do __aa_precmd; done
printf "B precmd %.1f\n" $(( (SECONDS-s)*1000 ))
s=$SECONDS; for i in {1..200}; do __aa_table; done
printf "B table %.1f\n" $(( (SECONDS-s)*1000 ))
printf "B aliases %d\n" $#aliases' > $TMP/bench.zsh

typeset -A B
evalin "source $TMP/bench.zsh" | pick 'B ' | while read -r _ k v; do B[$k]=$v; done
print -r -- "  measured: preexec ${B[preexec]:-?} ms / 2000, precmd ${B[precmd]:-?} ms / 2000, table ${B[table]:-?} ms / 200, at ${B[aliases]:-?} aliases"
budget() {
	local name=$1 limit=$2 got=${B[$1]:-}
	if [[ -z $got ]]; then bad "$name measured" "a number" "nothing"; return 0; fi
	if (( got < limit )); then ok "$name $got ms < $limit ms"; else bad "$name under $limit ms" "< $limit" "$got"; fi
}
budget preexec 120
budget precmd 30
budget table 60

print -r -- ""
print -r -- "passed $PASS, failed $FAIL"
(( FAIL == 0 ))
