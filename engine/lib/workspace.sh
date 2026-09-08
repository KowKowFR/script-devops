#!/usr/bin/env bash
# lib/workspace.sh — Gestion des workspaces (projets sauvegardés en série).
#
# Chaque workspace a son propre état dans runs/<nom>/ :
#   runs/
#     default/
#       .bootstrap-env
#       .bootstrap-state
#       .bootstrap.log
#       tp-devops-agent-ia/      (projet généré pour ce workspace)
#     tp1/
#       …
#     prod/
#       …
#
# Le bootstrap utilise un seul workspace à la fois (sélectionné via --workspace,
# défaut "default"). Pour basculer, on relance avec --workspace <autre>.
#
# Dépend de : SCRIPT_DIR, RUNS_DIR, ui_* (optionnel pour ws_migrate_legacy_quiet).

# Caractères autorisés dans un nom de workspace : a-z, A-Z, 0-9, _, -
_ws_valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,40}$ ]]
}

ws_default_name() {
  echo "default"
}

ws_dir() {
  echo "${RUNS_DIR}/$1"
}

ws_exists() {
  [[ -d "$(ws_dir "$1")" ]]
}

ws_list() {
  # Affiche les workspaces existants avec leur avancement.
  # Format : nom  étapes_done/total  modifié_le
  if [[ ! -d "$RUNS_DIR" ]]; then
    echo "Aucun workspace (lance ./bootstrap.sh pour en créer un)."
    return 0
  fi

  local has_any=0
  local ws_path name state_file count last_modif human_date
  for ws_path in "$RUNS_DIR"/*/; do
    [[ -d "$ws_path" ]] || continue
    has_any=1
    name=$(basename "$ws_path")
    state_file="${ws_path%/}/.bootstrap-state"
    count=0
    [[ -f "$state_file" ]] && count=$(grep -cv '^$' "$state_file" 2>/dev/null || echo 0)
    if [[ -f "$state_file" ]]; then
      # macOS stat -f, Linux stat -c (fallback ls)
      last_modif=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$state_file" 2>/dev/null \
                   || stat -c '%y' "$state_file" 2>/dev/null \
                   || echo "—")
      human_date="${last_modif:0:16}"
    else
      human_date="(vide)"
    fi
    printf "  %-20s %s étapes ✓   modifié : %s\n" "$name" "$count/18" "$human_date"
  done

  if (( has_any == 0 )); then
    echo "Aucun workspace (lance ./bootstrap.sh pour en créer un)."
  fi
}

ws_create() {
  # Crée le dossier d'un workspace si absent.
  local name="$1"
  if ! _ws_valid_name "$name"; then
    echo "Nom invalide : '$name' (autorisé : a-z, A-Z, 0-9, _, -, max 40)" >&2
    return 1
  fi
  mkdir -p "$(ws_dir "$name")"
}

ws_delete() {
  # Supprime un workspace (avec confirmation appelant ailleurs).
  local name="$1"
  if [[ "$name" == "default" ]]; then
    echo "Refus de supprimer le workspace 'default' (utilise --reset pour effacer son contenu)" >&2
    return 1
  fi
  if ! ws_exists "$name"; then
    echo "Workspace '$name' inexistant" >&2
    return 1
  fi
  rm -rf "$(ws_dir "$name")"
  echo "✓ Workspace '$name' supprimé"
}

# Migration des fichiers à la racine (ancien layout) vers runs/default/.
# Idempotent : ne fait rien si déjà migré.
ws_migrate_legacy() {
  local quiet="${1:-}"
  local legacy_env="${SCRIPT_DIR}/.bootstrap-env"
  local legacy_state="${SCRIPT_DIR}/.bootstrap-state"
  local legacy_log="${SCRIPT_DIR}/.bootstrap.log"
  local legacy_lock="${SCRIPT_DIR}/.bootstrap.lock"
  local legacy_project="${SCRIPT_DIR}/tp-devops-agent-ia"

  # Rien à migrer ?
  if [[ ! -e "$legacy_env" && ! -e "$legacy_state" && ! -e "$legacy_log" && ! -d "$legacy_project" ]]; then
    return 0
  fi

  local default_dir="${RUNS_DIR}/default"
  mkdir -p "$default_dir"

  [[ "$quiet" == "quiet" ]] || echo "→ Migration vers le nouveau layout multi-workspace…"

  # Si la cible existe déjà ET la source aussi → on garde la cible (déjà migrée), on retire la source legacy.
  # Sinon on déplace.
  local f src dst
  for f in .bootstrap-env .bootstrap-state .bootstrap.log .bootstrap.lock; do
    src="${SCRIPT_DIR}/$f"
    dst="${default_dir}/$f"
    if [[ -e "$src" ]]; then
      if [[ -e "$dst" ]]; then
        [[ "$quiet" == "quiet" ]] || echo "  ↷  $f déjà dans runs/default/, ancien retiré"
        rm -f "$src"
      else
        mv "$src" "$dst"
        [[ "$quiet" == "quiet" ]] || echo "  ✓  $f → runs/default/"
      fi
    fi
  done

  # Le dossier de projet
  if [[ -d "$legacy_project" ]]; then
    local dst_project="${default_dir}/tp-devops-agent-ia"
    if [[ -d "$dst_project" ]]; then
      [[ "$quiet" == "quiet" ]] || echo "  ⚠  tp-devops-agent-ia déjà dans runs/default/, ancien GARDÉ à la racine (à toi de trancher)"
    else
      mv "$legacy_project" "$dst_project"
      [[ "$quiet" == "quiet" ]] || echo "  ✓  tp-devops-agent-ia/ → runs/default/"
    fi
  fi

  [[ "$quiet" == "quiet" ]] || echo "✓ Migration terminée — utilise --workspace default pour ce projet"
}
