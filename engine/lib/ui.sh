#!/usr/bin/env bash
# lib/ui.sh — Helpers UI (gum + fallback texte).
#
# Exporte :
#   HAS_GUM (0|1)             — détecté par ensure_gum() de lib/prereqs.sh
#   C_* (palette ANSI + hex)
#   ui_step, ui_info, ui_ok, ui_warn, ui_err, ui_skip
#   ui_prompt VAR_NAME "Question" [default] [--password|--optional]
#   ui_choose VAR_NAME "Question" default opt1 opt2 ...
#   ui_confirm "Question" [default=y]
#   ui_spin "Titre" -- cmd args...
#   gum_box "title..." [body_lines...]    — bloc gum/double border navy
#
# Pré-requis : variables HAS_GUM lue à l'appel (peut être 0 au début).

# ----- Palette projet -------------------------------------------------------
readonly C_NAVY_HEX='#1E2761'
readonly C_CORAL_HEX='#F96167'
readonly C_GREEN_HEX='#2C8B5A'

# ----- Couleurs ANSI (fallback texte) ---------------------------------------
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_NAVY='\033[38;5;25m'
readonly C_CORAL='\033[38;5;203m'
readonly C_GREEN='\033[38;5;35m'
readonly C_YELLOW='\033[38;5;214m'
readonly C_RED='\033[38;5;160m'
readonly C_BLUE='\033[38;5;39m'

HAS_GUM="${HAS_GUM:-0}"

# ----- Helpers internes -----------------------------------------------------
_has_gum() { (( HAS_GUM == 1 )); }

# ----- Messages courts ------------------------------------------------------
# `printf '%b\n'` plutôt que `echo -e` : portable peu importe le shell
# (certains echo n'interprètent pas `-e` et le réimpriment littéralement).
ui_info()  { printf '%b\n' "${C_BLUE}ℹ${C_RESET}  $*"; }
ui_ok()    { printf '%b\n' "${C_GREEN}✓${C_RESET}  $*"; }
ui_warn()  { printf '%b\n' "${C_YELLOW}⚠${C_RESET}  $*"; }
ui_err()   { printf '%b\n' "${C_RED}✗${C_RESET}  $*" >&2; }
ui_skip()  { printf '%b\n' "${C_DIM}↷  $* (déjà fait)${C_RESET}"; }

# ----- Bloc d'étape ---------------------------------------------------------
ui_step() {
  local title="$*"
  if _has_gum; then
    gum style \
      --border rounded \
      --border-foreground "$C_NAVY_HEX" \
      --foreground "$C_NAVY_HEX" \
      --bold \
      --padding "0 2" \
      --margin "1 0 0 0" \
      "${title}"
  else
    printf "%b\n" "\n${C_NAVY}${C_BOLD}━━━ ${title} ━━━${C_RESET}"
  fi
}

# ----- Boîte (récap, banner, succès…) ---------------------------------------
# Usage : gum_box border_color "Titre" [ligne...]
gum_box() {
  local color="$1" title="$2"
  shift 2
  if _has_gum; then
    gum style \
      --border double \
      --border-foreground "$color" \
      --foreground "$color" \
      --bold \
      --padding "1 2" \
      --margin "1 0" \
      "${title}" \
      "" \
      "$@"
  else
    local ansi="$C_NAVY"
    [[ "$color" == "$C_GREEN_HEX" ]] && ansi="$C_GREEN"
    echo
    printf "%b\n" "${ansi}${C_BOLD}╔═══ ${title} ═══╗${C_RESET}"
    local line
    for line in "$@"; do
      [[ -z "$line" ]] && echo || echo "  ${line}"
    done
    printf "%b\n" "${ansi}${C_BOLD}╚═══════════════╝${C_RESET}"
    echo
  fi
}

# ----- Prompt unifié --------------------------------------------------------
# Usage : ui_prompt VAR_NAME "Question" [default] [--password|--optional]
# - Si la variable est déjà non-vide, on skip.
# - --password : masque la saisie.
# - --optional : accepte une réponse vide (sans erreur).
ui_prompt() {
  local var_name="$1" question="$2" default=""
  shift 2

  local mode="required"
  while (( $# > 0 )); do
    case "$1" in
      --password) mode="password" ;;
      --optional) mode="optional" ;;
      *) default="$1" ;;
    esac
    shift
  done

  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    local shown="$current"
    [[ "$mode" == "password" ]] && shown="****"
    ui_skip "${var_name} déjà défini (${shown})"
    return 0
  fi

  # En mode non-interactif (--config / Web UI) : ne JAMAIS prompter.
  # Si la valeur attendue est manquante, on échoue clairement (au lieu de
  # bloquer indéfiniment sur un gum input sans TTY).
  if [[ "${BOOTSTRAP_NONINTERACTIVE:-0}" == "1" ]]; then
    if [[ "$mode" == "optional" ]]; then
      # Optionnel : on accepte le vide
      printf -v "$var_name" '%s' ""
      # shellcheck disable=SC2163
      export "${var_name?}"
      return 0
    fi
    ui_err "Variable requise non définie : ${var_name} (mode non-interactif)"
    ui_info "Ajoute ${var_name}=\"...\" dans ton fichier .bootstrap-env"
    exit 1
  fi

  local answer=""
  if _has_gum; then
    local args=(
      --header "${question}"
      --prompt "› "
      --prompt.foreground "$C_CORAL_HEX"
      --header.foreground "$C_NAVY_HEX"
    )
    [[ "$mode" == "password" ]] && args+=(--password)
    if [[ -n "$default" ]]; then
      args+=(--placeholder "${default}" --value "${default}")
    elif [[ "$mode" == "optional" ]]; then
      args+=(--placeholder "(vide)")
    fi
    answer=$(gum input "${args[@]}")
  else
    local hint=""
    if [[ "$mode" == "password" ]]; then
      hint=" (caché)"
    elif [[ -n "$default" ]]; then
      hint=" [${C_DIM}${default}${C_RESET}]"
    elif [[ "$mode" == "optional" ]]; then
      hint=" [${C_DIM}vide${C_RESET}]"
    fi
    printf '%b' "${C_CORAL}?${C_RESET}  ${question}${hint} "
    if [[ "$mode" == "password" ]]; then
      read -rs answer
      echo
    else
      read -r answer
      answer="${answer:-$default}"
    fi
  fi

  if [[ -z "$answer" && "$mode" != "optional" ]]; then
    ui_err "Valeur requise pour ${var_name}"
    exit 1
  fi

  printf -v "$var_name" '%s' "$answer"
  # shellcheck disable=SC2163
  export "${var_name?}"
}

# ----- Sélection d'option ---------------------------------------------------
# Usage : ui_choose VAR_NAME "Question" default opt1 opt2 ...
ui_choose() {
  local var_name="$1" question="$2" default="$3"
  shift 3
  local options=("$@")
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    ui_skip "${var_name} déjà défini (${current})"
    return 0
  fi

  # Non-interactif : fallback sur le default sans demander
  if [[ "${BOOTSTRAP_NONINTERACTIVE:-0}" == "1" ]]; then
    printf -v "$var_name" '%s' "$default"
    # shellcheck disable=SC2163
    export "${var_name?}"
    return 0
  fi

  local answer=""
  if _has_gum; then
    answer=$(gum choose \
      --header "${question}" \
      --header.foreground "$C_NAVY_HEX" \
      --cursor.foreground "$C_CORAL_HEX" \
      --selected "${default}" \
      "${options[@]}")
  else
    printf "%b\n" "${C_CORAL}?${C_RESET}  ${question}"
    local i=1 opt marker
    for opt in "${options[@]}"; do
      marker=" "
      [[ "$opt" == "$default" ]] && marker="*"
      echo "    ${marker} ${i}) ${opt}"
      i=$((i + 1))
    done
    printf '%b' "  Choix [${default}] › "
    local idx
    read -r idx
    if [[ -z "$idx" ]]; then
      answer="$default"
    elif [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#options[@]} )); then
      answer="${options[$((idx - 1))]}"
    else
      answer="$idx"
    fi
  fi

  [[ -z "$answer" ]] && answer="$default"
  printf -v "$var_name" '%s' "$answer"
  # shellcheck disable=SC2163
  export "${var_name?}"
}

# ----- Confirmation oui/non -------------------------------------------------
ui_confirm() {
  local question="$1" default="${2:-y}"

  if _has_gum; then
    local args=(
      --selected.background "$C_NAVY_HEX"
      --prompt.foreground "$C_NAVY_HEX"
    )
    [[ "$default" == "n" ]] && args+=(--default=false)
    gum confirm "${args[@]}" "${question}"
    return $?
  fi

  local hint="[Y/n]"
  [[ "$default" == "n" ]] && hint="[y/N]"
  printf '%b' "${C_CORAL}?${C_RESET}  ${question} ${hint} "
  local answer
  read -r answer
  answer="${answer:-$default}"
  answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
  [[ "$answer" == "y" || "$answer" == "yes" || "$answer" == "o" || "$answer" == "oui" ]]
}

# ----- Spinner pour commande longue -----------------------------------------
# Usage : ui_spin "Titre" -- cmd args...
ui_spin() {
  local title="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift

  if _has_gum; then
    gum spin \
      --spinner dot \
      --title "${title}" \
      --spinner.foreground "$C_NAVY_HEX" \
      --title.foreground "$C_NAVY_HEX" \
      --show-output \
      -- "$@"
  else
    ui_info "${title}"
    "$@"
  fi
}
