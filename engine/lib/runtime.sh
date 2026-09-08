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

# _RESULT_EMITTED — posé à 1 dès qu'une ligne de résultat a été imprimée sur
# stdout (par emit_ok ou emit_fail). Lu par le filet de sécurité EXIT posé par
# install_error_trap : si personne n'a émis de ligne quand le shell sort,
# c'est que le contrat est rompu (ex. variable non liée sous `set -u`, qui ne
# passe PAS par le trap ERR) et il faut en émettre une quand même.
_RESULT_EMITTED=0

# emit_ok [JSON_OBJET] — imprime le résultat de succès sur stdout.
# N'appelle pas exit : c'est l'étape qui décide de sa sortie.
emit_ok() {
  local data="${1:-null}"
  if ! printf '%s' "$data" | jq -e . >/dev/null 2>&1; then
    data="null"
  fi
  _RESULT_EMITTED=1
  jq -cn --argjson data "$data" '{ok: true, data: $data}'
}

# emit_fail MESSAGE — imprime le résultat d'échec sur stdout.
emit_fail() {
  _RESULT_EMITTED=1
  jq -cn --arg error "${1:-erreur inconnue}" '{ok: false, error: $error}'
}

# _runtime_begin_step NOM — à appeler par le dispatcher (run_one_step, dans
# bootstrap.sh) juste avant CHAQUE étape, aussi bien en mode --step qu'en
# mode --all. Repositionne _CURRENT_STEP et RÉARME _RESULT_EMITTED à 0.
#
# Pourquoi c'est indispensable : les gardes anti-doublon (error_handler et
# _exit_guard, plus bas) répondent à la question « une ligne de résultat a-t-
# elle déjà été émise ? ». Sans ce réarmement, cette question est posée à
# l'échelle du PROCESS entier, pas de l'étape courante. En mode --step ça ne
# change rien (une seule étape par process). En mode --all, plusieurs étapes
# tournent dans le même process : dès qu'une étape a émis une fois, la garde
# avalerait silencieusement le résultat de TOUTE étape suivante — l'échec
# partirait sur stderr mais disparaîtrait de stdout, alors que le contrat de
# --all est précisément une ligne JSON PAR étape (cf. bootstrap.sh).
_runtime_begin_step() {
  _CURRENT_STEP="${1:-}"
  _RESULT_EMITTED=0
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
  # Même garde que _exit_guard : si une ligne de résultat a déjà été émise
  # (ex. emit_ok suivi d'une commande qui échoue plus loin dans la même
  # étape), on ne double-imprime jamais sur stdout. Le diagnostic ci-dessus
  # part quand même sur stderr — c'est stdout qui doit rester intact.
  if [[ "$_RESULT_EMITTED" -ne 1 ]]; then
    emit_fail "étape '${_CURRENT_STEP:-inconnue}' : ${cmd} (ligne ${line}, exit ${exit_code})"
  fi
  exit 1
}

install_error_trap() {
  # `set -E` propage ERR aux fonctions et sous-shells. À appeler après `set -e`.
  set -E
  trap 'error_handler "$LINENO" "$BASH_COMMAND"' ERR
  # Filet de sécurité, PAS un remplacement du trap ERR : une variable non liée
  # sous `set -u` (ou tout autre chemin de sortie du shell) ne déclenche jamais
  # ERR, seulement EXIT. Sans ce filet, l'engine sortirait sans la moindre
  # ligne JSON — exactement ce que le contrat interdit.
  trap '_exit_guard "$?"' EXIT
}

# _exit_guard CODE — posé par install_error_trap (trap EXIT). N'émet quelque
# chose QUE si aucune ligne de résultat n'a encore été imprimée ; préserve
# toujours le code de sortie d'origine (ne le transforme jamais en 0).
#
# Piège bash vérifié empiriquement : sur une variable non liée sous `set -u`,
# le shell termine avec le statut 1 quand AUCUN trap EXIT n'est posé — mais dès
# qu'un trap EXIT existe, ce trap voit encore le "$?" de la dernière commande
# RÉUSSIE avant l'erreur (donc 0), pas le 1 que bash aurait utilisé sans trap.
# Faire confiance à "$?" ici mentirait exactement dans le cas qu'on corrige.
# Donc : si on n'a rien émis et que "$?" vaut 0, on sait que c'est ce piège et
# on force 1 (le code que bash aurait produit nativement) — jamais 0 en sortie
# quand aucun résultat n'a été émis.
_exit_guard() {
  local code="$1"
  if [[ "$_RESULT_EMITTED" -ne 1 ]]; then
    if [[ "$code" -eq 0 ]]; then
      code=1
    fi
    ui_err "L'engine est sorti sans résultat (étape='${_CURRENT_STEP:-<inconnue>}', code=${code})"
    emit_fail "l'engine est sorti sans émettre de résultat (étape='${_CURRENT_STEP:-<inconnue>}', code=${code})"
  fi
  exit "$code"
}
