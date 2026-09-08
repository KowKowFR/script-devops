#!/usr/bin/env bash
# lib/prereqs.sh — Détection/installation de gum + vérification des pré-requis.

# ----- Détection / installation de gum --------------------------------------
ensure_gum() {
  if command -v gum >/dev/null 2>&1; then
    HAS_GUM=1
    return 0
  fi

  echo
  printf "%b\n" "${C_YELLOW}⚠${C_RESET}  gum n'est pas installé (TUI dégradée)."
  echo "    gum est un petit outil TUI (charm.sh/gum) qui rend les prompts beaucoup plus agréables."
  echo

  if [[ "${BOOTSTRAP_NONINTERACTIVE:-0}" == "1" ]]; then
    printf "%b\n" "${C_DIM}Mode non-interactif : on continue sans gum.${C_RESET}"
    return 0
  fi

  local installer=""
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    installer="brew install gum"
  elif command -v apt >/dev/null 2>&1; then
    installer="sudo mkdir -p /etc/apt/keyrings && curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg && echo 'deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *' | sudo tee /etc/apt/sources.list.d/charm.list && sudo apt update && sudo apt install -y gum"
  fi

  if [[ -z "$installer" ]]; then
    echo "    Installation manuelle : https://github.com/charmbracelet/gum#installation"
    return 0
  fi

  read -r -p "Installer gum maintenant ? [Y/n] " ans
  ans="${ans:-y}"
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  if [[ "$ans" != "y" && "$ans" != "yes" && "$ans" != "o" ]]; then
    return 0
  fi

  eval "$installer"
  if command -v gum >/dev/null 2>&1; then
    HAS_GUM=1
    printf "%b\n" "${C_GREEN}✓${C_RESET}  gum installé"
  else
    printf "%b\n" "${C_RED}✗${C_RESET}  Installation de gum échouée, fallback texte."
  fi
}

# ----- Vérification des pré-requis CLI --------------------------------------
check_prereqs() {
  ui_step "Vérification des pré-requis"

  if state_has "prereqs_checked"; then
    ui_skip "Pré-requis déjà validés"
    return 0
  fi

  local required=("git" "gh" "ssh" "ssh-keygen" "curl" "jq")
  local optional=("docker" "claude" "kubectl" "gum")
  local missing=() tool

  for tool in "${required[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      ui_ok "${tool} présent"
    else
      ui_err "${tool} manquant (requis)"
      missing+=("$tool")
    fi
  done

  for tool in "${optional[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      ui_ok "${tool} présent"
    else
      ui_warn "${tool} manquant (optionnel mais recommandé)"
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    ui_err "Outils manquants : ${missing[*]}"
    echo
    echo "Installation suggérée :"
    echo "  macOS  : brew install ${missing[*]}"
    echo "  Linux  : sudo apt install ${missing[*]}"
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    ui_warn "GitHub CLI non authentifié"
    ui_info "Lancement de 'gh auth login'…"
    gh auth login
  fi
  ui_ok "GitHub CLI authentifié"

  state_mark "prereqs_checked"
}

# ----- Installation de sshpass (mode password) ------------------------------
ensure_sshpass() {
  command -v sshpass >/dev/null 2>&1 && return 0

  ui_warn "sshpass n'est pas installé — requis pour l'auth par mot de passe"
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    ui_info "Installation : brew install hudochenkov/sshpass/sshpass"
    if ui_confirm "Installer sshpass maintenant ?"; then
      brew install hudochenkov/sshpass/sshpass
      return 0
    fi
    ui_err "sshpass requis pour continuer en mode password"
    exit 1
  fi

  if command -v apt >/dev/null 2>&1; then
    sudo apt install -y sshpass
    return 0
  fi

  ui_err "Installe sshpass manuellement puis relance"
  exit 1
}
