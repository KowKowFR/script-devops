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

# ----- Garde anti-doublon à l'échelle de l'ÉTAPE, pas du process -----------
# Régression Task 6 (round 3) : _RESULT_EMITTED est une globale du process.
# Le dispatcher (run_one_step, bootstrap.sh) appelle _runtime_begin_step avant
# CHAQUE étape, en mode --step comme en mode --all, pour la réarmer. Sans ce
# réarmement, dès qu'une étape a émis une fois dans le process, la garde
# avale silencieusement le résultat de toute étape suivante (mode --all,
# plusieurs étapes/process) — l'échec part sur stderr mais disparaît de
# stdout. Ce test échoue si _runtime_begin_step cesse de remettre
# _RESULT_EMITTED à 0.

UI="$ENGINE_DIR/lib/ui.sh"

# Deux étapes dans le MÊME process (reproduit la boucle --all) : la première
# réussit ; la seconde échoue via une VRAIE commande qui casse (`false`), donc
# via le trap ERR / error_handler — c'est le chemin réellement gardé par
# _RESULT_EMITTED, pas un emit_fail explicite (qui n'est jamais conditionné à
# la garde). Sans réarmement, error_handler du round 2 verrait déjà
# _RESULT_EMITTED=1 (posé par le emit_ok de la 1re étape) et avalerait la
# ligne d'échec de la seconde ; avec réarmement, chaque étape produit la sienne.
multi_step_two='
  set -euo pipefail
  source "'"$UI"'"
  source "'"$RT"'"
  install_error_trap
  step_a() { emit_ok "{\"n\":1}"; }
  step_b() { false; }
  for s in a b; do
    _runtime_begin_step "$s"
    "step_$s"
  done
'
out=$(bash -c "$multi_step_two" 2>/dev/null)
lines=$(bash -c "$multi_step_two" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "2" "$lines" "deux étapes (succès puis échec de commande) dans le même process → 2 lignes JSON"
assert_eq "true"  "$(printf '%s\n' "$out" | sed -n '1p' | jq -r .ok)" "ligne 1 = succès de la 1re étape"
assert_eq "false" "$(printf '%s\n' "$out" | sed -n '2p' | jq -r .ok)" "ligne 2 = échec de la 2e étape, non avalé"
assert_contains "$(printf '%s\n' "$out" | sed -n '2p' | jq -r .error)" "false" \
  "le message d'échec de la 2e étape nomme la commande fautive"

# Trois étapes qui réussissent toutes dans le même process → 3 lignes.
multi_step_three='
  source "'"$RT"'"
  for s in 1 2 3; do
    _runtime_begin_step "step$s"
    emit_ok "{\"n\":$s}"
  done
'
lines3=$(bash -c "$multi_step_three" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "3" "$lines3" "trois étapes qui réussissent dans le même process → 3 lignes JSON"

# Non-régression round 2 : UNE seule étape (mode --step) qui émet puis
# rencontre un échec de commande ensuite → toujours 1 seule ligne (le doublon
# intra-étape reste bloqué, seul le réarmement INTER-étape doit changer).
one_step_then_fail='
  set -euo pipefail
  source "'"$UI"'"
  source "'"$RT"'"
  install_error_trap
  _runtime_begin_step "case_unique"
  emit_ok "{\"x\":1}"
  false
'
lines_one=$(bash -c "$one_step_then_fail" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "1" "$lines_one" "une seule étape : succès puis échec de commande → toujours 1 ligne (non-régression round 2)"

finish
