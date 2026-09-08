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

assert_contains() {
  # assert_contains TEXTE MOTIF MESSAGE
  if printf '%s' "$1" | grep -qF -- "$2"; then
    _t_ok "$3"
  else
    _t_fail "$3" "motif absent : [$2]"
  fi
}

assert_not_contains() {
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
