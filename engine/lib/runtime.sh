#!/usr/bin/env bash
# lib/runtime.sh — Logging, lock file, trap d'erreur, dry-run.
#
# Dépend de : LOG_FILE, LOCK_FILE, ui_*, _CURRENT_STEP (mis à jour par bootstrap.sh).

# ----- Logging --------------------------------------------------------------
# Tee tout stdout/stderr vers LOG_FILE en préfixant d'un timestamp.
# Les codes ANSI sont préservés (ouvre le log avec `less -R` ou `cat`).
#
# Notes d'implémentation :
# - On évite `awk strftime` (BSD awk de macOS ne le supporte pas).
# - Le wrapper Bash + `date` est plus lent mais portable Linux/macOS.
# - La process substitution `>(...)` est cachée dans un `eval` : ainsi le
#   fichier se parse correctement même en POSIX sh (qui ne connaît pas `>(...)`)
#   et on peut tester sa dispo à l'exécution avant de l'activer.
log_init() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "=== bootstrap.sh started at $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"

  # Détecte si la process substitution fonctionne dans ce shell.
  if ! eval 'exec 7> >(cat >/dev/null) && exec 7>&-' 2>/dev/null; then
    echo "[warn] Process substitution indisponible (shell POSIX ?) — .bootstrap.log désactivé" >&2
    return 0
  fi

  eval '
    exec  > >(while IFS= read -r line; do printf "[%s] %s\n"      "$(date +%H:%M:%S)" "$line"; done | tee -a "$LOG_FILE")
    exec 2> >(while IFS= read -r line; do printf "[%s][err] %s\n" "$(date +%H:%M:%S)" "$line"; done | tee -a "$LOG_FILE" >&2)
  '
}

# ----- Lock file (anti-concurrence) -----------------------------------------
acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      ui_err "Une autre instance de bootstrap.sh tourne (PID $pid)"
      ui_info "Si c'est faux : rm ${LOCK_FILE}"
      exit 1
    fi
    # Stale lock : on récupère
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  trap 'release_lock' EXIT
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# ----- Trap d'erreur global -------------------------------------------------
# _CURRENT_STEP est tenu à jour par run_pipeline pour contextualiser l'erreur.
_CURRENT_STEP=""

error_handler() {
  local exit_code=$?
  local line="$1"
  local cmd="$2"
  ui_err "Échec à l'étape '${_CURRENT_STEP:-<orchestration>}' (ligne $line, exit=$exit_code)"
  ui_info "Commande : ${cmd}"
  ui_info "Log complet : ${LOG_FILE}"
  ui_info "Reprendre depuis l'état courant : ./bootstrap.sh"
  exit "$exit_code"
}

install_error_trap() {
  # `set -E` propage ERR aux fonctions/subshells. Doit être appelé après `set -e`.
  set -E
  trap 'error_handler "$LINENO" "$BASH_COMMAND"' ERR
}
