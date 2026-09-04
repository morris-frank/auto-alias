# auto-alias 0.1 — zsh integration, emitted by `auto-alias init zsh`. Do not edit.
# M1: rule 1 (match) only. No binary call, no state dir, no proposals.
#
# The whole file is one anonymous function. A bare `return` at the top level of an
# `eval` terminates the *calling* script with no error, so a non-interactive shell
# that sources a file carrying the install line would silently stop there. Inside a
# function, `return` only leaves the function. All state below is declared -g.
() {
[[ -o interactive ]] || return 0
zmodload -F zsh/datetime p:EPOCHSECONDS || return 0
zmodload -F zsh/parameter p:aliases || return 0
autoload -Uz add-zsh-hook

typeset -gA _aa_rev _aa_equiv _aa_seen
typeset -g  _aa_msg='' _aa_key='' _aa_name='' _aa_tail='' _aa_dim='' _aa_off=''
typeset -gi _aa_na=-1
: ${AUTO_ALIAS_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/auto-alias}
: ${AUTO_ALIAS_COOLDOWN:=3600}
[[ -z $NO_COLOR && -t 2 ]] && { _aa_dim=$'\e[2m'; _aa_off=$'\e[0m'; }
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
  (( $#aliases == _aa_na )) || __aa_table
  [[ -n $_aa_msg ]] || return 0
  print -ru2 -- $_aa_dim$_aa_msg$_aa_off
  _aa_msg=''
}

add-zsh-hook -d preexec __aa_preexec; add-zsh-hook preexec __aa_preexec
add-zsh-hook -d precmd  __aa_precmd;  add-zsh-hook precmd  __aa_precmd
}
