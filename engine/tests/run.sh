#!/usr/bin/env bash
# engine/tests/run.sh — lance tous les engine/tests/test_*.sh.
# Usage : engine/tests/run.sh [motif]

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PATTERN="${1:-}"

total_fail=0
for f in "$TESTS_DIR"/test_*.sh; do
  [[ -f "$f" ]] || continue
  if [[ -n "$PATTERN" ]] && ! printf '%s' "$(basename "$f")" | grep -q "$PATTERN"; then
    continue
  fi
  printf '\n== %s\n' "$(basename "$f")"
  bash "$f" || total_fail=$((total_fail + 1))
done

printf '\n=== syntaxe (bash -n) ===\n'
for f in "$ENGINE_DIR"/bootstrap.sh "$ENGINE_DIR"/lib/*.sh "$ENGINE_DIR"/tools/*.sh; do
  [[ -f "$f" ]] || continue
  if bash -n "$f" 2>/dev/null; then
    printf '  ok   %s\n' "${f#"$ENGINE_DIR"/}"
  else
    printf '  FAIL %s\n' "${f#"$ENGINE_DIR"/}"
    bash -n "$f" || true
    total_fail=$((total_fail + 1))
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  printf '\n=== shellcheck (niveau error) ===\n'
  # On ne liste que les fichiers réellement présents : un glob non résolu
  # (ex. tools/*.sh tant que ce dossier est vide) resterait littéral et
  # ferait planter shellcheck sur un nom de fichier inexistant.
  sc_files=()
  for f in "$ENGINE_DIR"/bootstrap.sh "$ENGINE_DIR"/lib/*.sh "$ENGINE_DIR"/tools/*.sh; do
    [[ -f "$f" ]] && sc_files+=("$f")
  done
  if [[ "${#sc_files[@]}" -eq 0 ]]; then
    printf '  (aucun fichier à vérifier)\n'
  elif shellcheck --severity=error --shell=bash "${sc_files[@]}"; then
    printf '  ok   aucune erreur\n'
  else
    total_fail=$((total_fail + 1))
  fi
else
  printf '\n  (shellcheck absent — vérification sautée)\n'
fi

printf '\n'
if [[ "$total_fail" -eq 0 ]]; then
  printf 'TOUT PASSE\n'; exit 0
fi
printf '%d fichier(s) de test en échec\n' "$total_fail"; exit 1
