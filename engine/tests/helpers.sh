#!/usr/bin/env bash
# engine/tests/helpers.sh — micro-harnais d'assertions, sans dépendance externe.
# Chaque test_*.sh source ce fichier, appelle des assert_*, puis finish.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ENGINE_DIR/.." && pwd)"
export TESTS_DIR ENGINE_DIR REPO_ROOT

_T_PASS=0
_T_FAIL=0

_t_ok()   { _T_PASS=$((_T_PASS + 1)); printf '  ok   %s\n' "$1"; }
_t_fail() {
  _T_FAIL=$((_T_FAIL + 1))
  printf '  FAIL %s\n' "$1"
  shift
  local line
  for line in "$@"; do printf '       %s\n' "$line"; done
}

assert_eq() {
  # assert_eq ATTENDU OBTENU MESSAGE
  if [[ "$1" == "$2" ]]; then
    _t_ok "$3"
  else
    _t_fail "$3" "attendu : [$1]" "obtenu  : [$2]"
  fi
}


# _assert_reject_multiline_pattern MOTIF MESSAGE — code 0 (et un FAIL déjà
# émis) si MOTIF contient un retour à la ligne littéral, 1 sinon.
#
# Piège POSIX vérifié sur cette machine : `grep -F` avec un motif
# multi-lignes ne cherche PAS une sous-chaîne contiguë — il traite chaque
# ligne du motif comme une alternative séparée (un OU). Un motif
# `$'a\nb'` matche donc tout texte contenant SOIT "a" SOIT "b", jamais "a"
# suivi de "b". Une assertion écrite ainsi peut rester verte alors que le
# texte qu'elle est censée protéger a disparu — exactement le défaut que ce
# harnais doit détecter, pas reproduire. D'où ce refus bruyant : mieux vaut
# un FAIL explicite qui dit pourquoi qu'un faux vert silencieux.
_assert_reject_multiline_pattern() {
  case "$1" in
    *$'\n'*)
      _t_fail "$2" \
        "motif invalide : contient un retour à la ligne" \
        "grep -F traite un motif multi-lignes comme plusieurs motifs" \
        "alternatifs (un OU), jamais une sous-chaîne contiguë (POSIX) —" \
        "l'assertion resterait verte même si le texte visé disparaissait." \
        "Découpe en plusieurs assert_contains/assert_not_contains mono-ligne."
      return 0
      ;;
  esac
  return 1
}

assert_contains() {
  # assert_contains TEXTE MOTIF MESSAGE
  _assert_reject_multiline_pattern "$2" "$3" && return
  if printf '%s' "$1" | grep -qF -- "$2"; then
    _t_ok "$3"
  else
    _t_fail "$3" "motif absent : [$2]"
  fi
}

assert_not_contains() {
  _assert_reject_multiline_pattern "$2" "$3" && return
  if printf '%s' "$1" | grep -qF -- "$2"; then
    _t_fail "$3" "motif présent alors qu'il ne devrait pas : [$2]"
  else
    _t_ok "$3"
  fi
}

assert_exit_code() {
  # assert_exit_code ATTENDU MESSAGE -- cmd args...
  local expected="$1" msg="$2"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$expected" ]]; then
    _t_ok "$msg"
  else
    _t_fail "$msg" "code attendu : $expected" "code obtenu  : $rc"
  fi
}

assert_valid_json() {
  # assert_valid_json TEXTE MESSAGE
  if printf '%s' "$1" | jq -e . >/dev/null 2>&1; then
    _t_ok "$2"
  else
    _t_fail "$2" "JSON invalide : [$1]"
  fi
}

finish() {
  printf '  → %d ok, %d échec(s)\n' "$_T_PASS" "$_T_FAIL"
  [[ "$_T_FAIL" -eq 0 ]]
}
