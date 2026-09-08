#!/usr/bin/env bash
# lib/state.sh — Suivi d'avancement (idempotence).
#
# Le fichier STATE_FILE contient un identifiant d'étape par ligne. Les fonctions :
#   state_has  ID        → 0 si présent
#   state_mark ID        → ajoute une ligne (no-op si déjà là)
#   state_unmark ID      → retire une ligne (utile pour "modifier les paramètres")
#   state_reset          → supprime STATE_FILE + ENV_FILE
#   state_show           → affiche la progression à partir de PIPELINE
#
# Dépend de : STATE_FILE, ENV_FILE, PIPELINE (array "id|title|fn"), ui_* helpers.

state_has()    { [[ -f "$STATE_FILE" ]] && grep -qx "$1" "$STATE_FILE"; }

state_mark() {
  mkdir -p "$(dirname "$STATE_FILE")"
  state_has "$1" || echo "$1" >> "$STATE_FILE"
}

state_unmark() {
  [[ -f "$STATE_FILE" ]] || return 0
  grep -vx "$1" "$STATE_FILE" > "${STATE_FILE}.tmp" || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

state_reset() {
  rm -f "$STATE_FILE" "$ENV_FILE"
  ui_ok "État réinitialisé"
}

state_show() {
  printf "%b\n" "${C_BOLD}Progression du bootstrap :${C_RESET}"
  local entry id
  for entry in "${PIPELINE[@]}"; do
    id="${entry%%|*}"
    [[ "$id" == _* ]] && continue   # étapes transitoires non trackées
    if state_has "$id"; then
      printf "%b\n" "  ${C_GREEN}✓${C_RESET} ${id}"
    else
      printf "%b\n" "  ${C_DIM}○${C_RESET} ${id}"
    fi
  done
}
