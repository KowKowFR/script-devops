#!/usr/bin/env bash
# lib/prepare_server.sh
# Préparation du serveur distant : Docker CE + plugin Compose, ufw, fail2ban.
# Ce script est envoyé via SSH par bootstrap.sh (step_prepare_server, Task 11).
# Idempotent : peut être relancé sans casser ce qui existe.
#
# REGISTRY_USER et REGISTRY_TOKEN arrivent via l'environnement : l'étape
# appelante les lit sur stdin (2 premières lignes, avant le corps de ce
# script) puis les exporte avant de lancer `bash -s`. Ils ne transitent
# jamais par la ligne de commande SSH (visible dans `ps`).

set -euo pipefail

# ----- Helpers --------------------------------------------------------------
log()  { echo "[remote] $*"; }
ok()   { echo "[remote] ✓ $*"; }
warn() { echo "[remote] ⚠ $*"; }

# ----- 1. Mise à jour APT minimale ------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
  log "Installation des paquets de base…"
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl ca-certificates gnupg lsb-release
fi
ok "Paquets de base présents"

# ----- 2. Docker CE + plugin Compose ----------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installation de Docker…"

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo usermod -aG docker "$USER"
  ok "Docker installé"
else
  ok "Docker déjà installé ($(docker --version))"
fi

# Le plugin compose peut manquer sur une install Docker plus ancienne.
if ! docker compose version >/dev/null 2>&1; then
  log "Installation du plugin docker compose…"
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-compose-plugin
fi
ok "docker compose : $(docker compose version --short 2>/dev/null || echo inconnu)"

# ----- 3. UFW ---------------------------------------------------------------
# Seul SSH reste ouvert. Les ports applicatifs sont ouverts un par un par
# l'étape open_firewall_ports (jalon 3), et uniquement depuis l'IP BunkerWeb.
# 80/443 ne sont plus ouverts : l'hôte cible n'est plus joignable publiquement.
# L'ancien port de l'API du cluster d'orchestration n'a plus lieu d'être.
if command -v ufw >/dev/null 2>&1; then
  sudo ufw --force default deny incoming
  sudo ufw --force default allow outgoing
  sudo ufw allow 22/tcp comment "SSH"
  sudo ufw delete allow 80/tcp   >/dev/null 2>&1 || true
  sudo ufw delete allow 443/tcp  >/dev/null 2>&1 || true
  sudo ufw delete allow 6443/tcp >/dev/null 2>&1 || true
  sudo ufw --force enable
  ok "UFW actif (22 seul ; ports applicatifs ouverts à la demande)"
fi

# ----- 4. fail2ban -----------------------------------------------------------
if ! command -v fail2ban-server >/dev/null 2>&1; then
  log "Installation de fail2ban…"
  sudo apt-get update -qq          # requis : le update de la section 1 est conditionnel
  sudo apt-get install -y -qq fail2ban
  sudo systemctl enable --now fail2ban
  ok "fail2ban installé et actif"
else
  ok "fail2ban déjà présent"
fi

# ----- 5. Authentification au registre --------------------------------------
# Le token arrive sur stdin, jamais en argument : un argument de ligne de
# commande est visible dans `ps` par tout utilisateur de la machine.
if [ -n "${REGISTRY_USER:-}" ]; then
  if [ -n "${REGISTRY_TOKEN:-}" ]; then
    printf '%s' "$REGISTRY_TOKEN" \
      | sudo docker login --username "$REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
      && ok "docker login réussi ($REGISTRY_USER)" \
      || warn "docker login échoué — les images privées seront inaccessibles"
    unset REGISTRY_TOKEN
  else
    warn "REGISTRY_TOKEN absent : pas de docker login"
  fi
fi

# ----- 6. MOTD DeployMatic --------------------------------------------------
# Banner ASCII affiché à chaque connexion SSH. Placé en 00-deploymatic pour
# passer avant le 00-header par défaut d'Ubuntu (ordre lexicographique).
log "Installation du MOTD DeployMatic…"

sudo tee /etc/update-motd.d/00-deploymatic > /dev/null <<'MOTD_EOF'
#!/bin/sh
# Banner DeployMatic — généré par bootstrap-tp/lib/prepare_server.sh

NAVY="\033[38;5;25m"
CORAL="\033[38;5;203m"
GREEN="\033[38;5;35m"
DIM="\033[2m"
RESET="\033[0m"
BOLD="\033[1m"

printf '%b' "${NAVY}${BOLD}"
cat <<'BANNER'

██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗
██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝
██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝
██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝
██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║
╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝
   ███╗   ███╗ █████╗ ████████╗██╗ ██████╗
   ████╗ ████║██╔══██╗╚══██╔══╝██║██╔════╝
   ██╔████╔██║███████║   ██║   ██║██║
   ██║╚██╔╝██║██╔══██║   ██║   ██║██║
   ██║ ╚═╝ ██║██║  ██║   ██║   ██║╚██████╗
   ╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝   ╚═╝ ╚═════╝
BANNER
printf '%b' "${RESET}"

# Sous-titre coral
printf "  ${CORAL}Chaîne DevSecOps automatisée — Docker Compose + GitHub Actions + Skills Claude Code${RESET}\n\n"

# Infos système
printf "  ${BOLD}Système${RESET}\n"
printf "    Hostname    : %s\n" "$(hostname)"
printf "    OS          : %s\n" "$(lsb_release -ds 2>/dev/null || uname -s)"
printf "    Uptime      : %s\n" "$(uptime -p 2>/dev/null || uptime)"
printf "    Load        : %s\n" "$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || echo n/a)"
echo

# Infos Docker
if command -v docker >/dev/null 2>&1; then
    printf "  ${BOLD}Docker${RESET}\n"
    printf "    Version     : %s\n" "$(docker --version 2>/dev/null | cut -d, -f1)"
    printf "    Conteneurs  : %s en marche / %s au total\n" \
      "$(docker ps -q 2>/dev/null | wc -l)" "$(docker ps -aq 2>/dev/null | wc -l)"
    echo
fi

printf "  ${DIM}» bootstrap-tp : ./bootstrap.sh claude  pour piloter via IA${RESET}\n\n"
MOTD_EOF

sudo chmod +x /etc/update-motd.d/00-deploymatic

# Désactive le motd-news (pub Ubuntu Pro/Canonical) pour un banner propre
if [ -f /etc/default/motd-news ]; then
    sudo sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news 2>/dev/null || true
fi

ok "MOTD DeployMatic installé (visible au prochain ssh)"

# ----- 7. Récapitulatif ----------------------------------------------------
echo
echo "═══════════════════════════════════════════════════════════"
echo "  Serveur préparé — récapitulatif"
echo "═══════════════════════════════════════════════════════════"
echo "  Hostname     : $(hostname)"
echo "  OS           : $(lsb_release -ds 2>/dev/null || uname -s)"
echo "  Kernel       : $(uname -r)"
echo "  Docker       : $(docker --version 2>/dev/null | head -c 60 || echo 'non installé')"
echo "  docker compose : $(docker compose version --short 2>/dev/null || echo 'non installé')"
echo "═══════════════════════════════════════════════════════════"
