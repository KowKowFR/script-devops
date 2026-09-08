#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

RT="$ENGINE_DIR/lib/runtime.sh"

# emit_ok imprime un JSON valide sur stdout, rien sur stderr
out=$(bash -c "source '$RT'; emit_ok '{\"port\":8080}'" 2>/dev/null)
assert_valid_json "$out" "emit_ok produit du JSON valide"
assert_eq "true"   "$(printf '%s' "$out" | jq -r .ok)"        "emit_ok → ok=true"
assert_eq "8080"   "$(printf '%s' "$out" | jq -r .data.port)" "emit_ok transporte data"

# emit_ok sans argument → data null
out=$(bash -c "source '$RT'; emit_ok" 2>/dev/null)
assert_eq "true" "$(printf '%s' "$out" | jq -r .ok)" "emit_ok sans data reste valide"

# une seule ligne sur stdout, quoi qu'il arrive
lines=$(bash -c "source '$RT'; ui_dummy() { :; }; emit_ok '{\"a\":1}'" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "1" "$lines" "emit_ok imprime exactement une ligne"

# emit_fail
out=$(bash -c "source '$RT'; emit_fail 'ça a cassé'" 2>/dev/null)
assert_eq "false"       "$(printf '%s' "$out" | jq -r .ok)"    "emit_fail → ok=false"
assert_eq "ça a cassé"  "$(printf '%s' "$out" | jq -r .error)" "emit_fail transporte le message"

# les guillemets dans un message ne cassent pas le JSON
out=$(bash -c "source '$RT'; emit_fail 'il a dit \"non\"'" 2>/dev/null)
assert_valid_json "$out" "emit_fail échappe les guillemets"

# die → code 2 par défaut, code personnalisable
assert_exit_code 2 "die sort en 2 par défaut" -- bash -c "source '$RT'; die 'fatal'"
assert_exit_code 1 "die accepte un code"      -- bash -c "source '$RT'; die 'souple' 1"
assert_exit_code 1 "retryable sort en 1"      -- bash -c "source '$RT'; retryable 'réessayable'"

# log_init ne doit plus exister
assert_not_contains "$(cat "$RT")" "log_init" "log_init a disparu de runtime.sh"

finish
