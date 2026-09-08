#!/usr/bin/env bash
# Vérifie que la réorganisation est faite et que le harnais fonctionne.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

assert_eq "1" "$([[ -f "$ENGINE_DIR/bootstrap.sh" ]] && echo 1 || echo 0)" \
  "engine/bootstrap.sh existe"
assert_eq "1" "$([[ -d "$ENGINE_DIR/lib" ]] && echo 1 || echo 0)" \
  "engine/lib/ existe"
assert_eq "0" "$([[ -f "$REPO_ROOT/bootstrap.sh" ]] && echo 1 || echo 0)" \
  "plus de bootstrap.sh à la racine"
assert_eq "1" "$(command -v jq >/dev/null 2>&1 && echo 1 || echo 0)" \
  "jq est disponible"

finish
