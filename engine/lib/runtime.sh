#!/usr/bin/env bash
# engine/lib/runtime.sh — contrat de sortie de l'engine et trap d'erreur.
#
# CONTRAT (invariant du projet, cf. docs) :
#   - Les logs partent sur stderr, en clair, ligne par ligne.
#   - stdout ne reçoit QUE la ligne de résultat finale, en JSON.
#   - Codes de sortie : 0 succès, 1 échec réessayable, 2 échec fatal.
#
# L'engine n'écrit aucun fichier de log : c'est l'appelant (worker du panel,
# ou le shell interactif) qui capture stderr. Le stdout doit rester pur JSON.

_CURRENT_STEP=""

# emit_ok [JSON_OBJET] — imprime le résultat de succès sur stdout.
# N'appelle pas exit : c'est l'étape qui décide de sa sortie.
emit_ok() {
  local data="${1:-null}"
  if ! printf '%s' "$data" | jq -e . >/dev/null 2>&1; then
    data="null"
  fi
  jq -cn --argjson data "$data" '{ok: true, data: $data}'
}

# emit_fail MESSAGE — imprime le résultat d'échec sur stdout.
emit_fail() {
  jq -cn --arg error "${1:-erreur inconnue}" '{ok: false, error: $error}'
}

# die MESSAGE [CODE] — échec fatal (défaut : 2, non réessayable).
die() {
  emit_fail "${1:-erreur fatale}"
  exit "${2:-2}"
}

# retryable MESSAGE — échec réessayable (code 1).
retryable() {
  emit_fail "${1:-erreur temporaire}"
  exit 1
}

# ----- Trap d'erreur global -------------------------------------------------
# Toute commande qui échoue sous `set -e` passe ici : on transforme la panne en
# résultat JSON pour que l'appelant n'ait jamais à parser du texte libre.
error_handler() {
  local exit_code=$?
  local line="$1"
  local cmd="$2"
  ui_err "Échec dans '${_CURRENT_STEP:-<engine>}' (ligne ${line}, exit=${exit_code})"
  ui_err "Commande : ${cmd}"
  emit_fail "étape '${_CURRENT_STEP:-inconnue}' : ${cmd} (ligne ${line}, exit ${exit_code})"
  exit 1
}

install_error_trap() {
  # `set -E` propage ERR aux fonctions et sous-shells. À appeler après `set -e`.
  set -E
  trap 'error_handler "$LINENO" "$BASH_COMMAND"' ERR
}
