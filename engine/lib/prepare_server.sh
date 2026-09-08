#!/usr/bin/env bash
# lib/prepare_server.sh
# Préparation du serveur distant : Docker, k3s, kubectl, ufw.
# Ce script est envoyé via SSH par bootstrap.sh.
# Idempotent : peut être relancé sans casser ce qui existe.

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

# ----- 2. Docker (utile pour debug local mais non indispensable pour k3s) ---
if ! command -v docker >/dev/null 2>&1; then
  log "Installation de Docker…"

  # Clé GPG officielle Docker
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  # Repo Docker
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin

  # Permettre à l'utilisateur courant d'utiliser docker sans sudo
  sudo usermod -aG docker "$USER"

  ok "Docker installé"
else
  ok "Docker déjà installé ($(docker --version))"
fi

# ----- 3. k3s ---------------------------------------------------------------
if ! command -v k3s >/dev/null 2>&1; then
  log "Installation de k3s…"

  # Le script officiel k3s, avec write-kubeconfig-mode pour le rendre lisible
  curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -

  # Attendre que k3s soit prêt
  log "Attente que k3s soit prêt…"
  for _ in {1..30}; do
    if sudo kubectl get nodes 2>/dev/null | grep -q " Ready "; then
      break
    fi
    sleep 2
  done

  ok "k3s installé"
else
  ok "k3s déjà installé"
fi

# Vérifier que k3s tourne
if ! sudo systemctl is-active --quiet k3s; then
  warn "k3s n'est pas actif, démarrage…"
  sudo systemctl start k3s
fi
ok "k3s actif"

# ----- 4. kubectl pour l'utilisateur courant --------------------------------
mkdir -p ~/.kube
if [[ ! -f ~/.kube/config ]] || ! grep -q "k3s" ~/.kube/config 2>/dev/null; then
  log "Configuration du kubeconfig pour ${USER}…"
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo chown "$USER:$USER" ~/.kube/config
  chmod 600 ~/.kube/config
fi
export KUBECONFIG=~/.kube/config

if kubectl get nodes >/dev/null 2>&1; then
  ok "kubectl fonctionne ($(kubectl get nodes --no-headers | wc -l) nœud(s))"
else
  warn "kubectl ne fonctionne pas — vérification manuelle requise"
fi

# ----- 5. Helm (utile pour des perspectives, non bloquant) -----------------
if ! command -v helm >/dev/null 2>&1; then
  log "Installation de Helm…"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash > /dev/null
  ok "Helm installé"
else
  ok "Helm déjà installé"
fi

# ----- 6. metrics-server (pour kubectl top et HPA) --------------------------
# k3s l'inclut souvent par défaut, on vérifie
if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  log "Installation de metrics-server…"
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # k3s nécessite --kubelet-insecure-tls (certificats auto-signés)
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' || true
  ok "metrics-server installé"
else
  ok "metrics-server déjà présent"
fi

# ----- 7. cert-manager (TLS automatique Let's Encrypt) ---------------------
# Installé uniquement si ACME_EMAIL est passé par le script appelant.
if [[ -n "${ACME_EMAIL:-}" ]]; then
  if ! kubectl get ns cert-manager >/dev/null 2>&1; then
    log "Installation de cert-manager (Helm)…"
    helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
    helm repo update jetstack >/dev/null 2>&1 || true
    helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager --create-namespace \
      --set installCRDs=true \
      --wait --timeout 5m
    ok "cert-manager installé"
  else
    ok "cert-manager déjà installé"
  fi
fi

# ----- 8. UFW (firewall) ----------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  if ! sudo ufw status | grep -q "Status: active"; then
    log "Configuration de UFW…"
    sudo ufw --force default deny incoming
    sudo ufw --force default allow outgoing
    sudo ufw allow 22/tcp comment "SSH"
    sudo ufw allow 80/tcp comment "HTTP"
    sudo ufw allow 443/tcp comment "HTTPS"
    sudo ufw allow 6443/tcp comment "k8s API"
    sudo ufw --force enable
    ok "UFW configuré et actif"
  else
    ok "UFW déjà actif"
  fi
fi

# ----- 9. fail2ban ----------------------------------------------------------
if ! command -v fail2ban-server >/dev/null 2>&1; then
  log "Installation de fail2ban…"
  sudo apt-get install -y -qq fail2ban
  sudo systemctl enable --now fail2ban
  ok "fail2ban installé et actif"
else
  ok "fail2ban déjà présent"
fi

# ----- 9. MOTD DeployMatic --------------------------------------------------
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
printf "  ${CORAL}Chaîne DevSecOps automatisée — k3s + GitHub Actions + Skills Claude Code${RESET}\n\n"

# Infos système
printf "  ${BOLD}Système${RESET}\n"
printf "    Hostname    : %s\n" "$(hostname)"
printf "    OS          : %s\n" "$(lsb_release -ds 2>/dev/null || uname -s)"
printf "    Uptime      : %s\n" "$(uptime -p 2>/dev/null || uptime)"
printf "    Load        : %s\n" "$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || echo n/a)"
echo

# Infos cluster k3s
if command -v kubectl >/dev/null 2>&1; then
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
    if [ -r "$KUBECONFIG" ] && kubectl get nodes >/dev/null 2>&1; then
        printf "  ${BOLD}Cluster Kubernetes${RESET}\n"
        kubectl get nodes --no-headers 2>/dev/null \
          | awk -v g="$(printf '\033[38;5;35m')" -v r="$(printf '\033[0m')" \
            '{printf "    %s : %s%s%s  (%s)\n", $1, ($2=="Ready"?g:""), $2, ($2=="Ready"?r:""), $5}'
        pods_running=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="Running"' | wc -l)
        pods_total=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
        printf "    Pods        : %s / %s running\n" "$pods_running" "$pods_total"
        echo
    fi
fi

printf "  ${DIM}» bootstrap-tp : ./bootstrap.sh claude  pour piloter via IA${RESET}\n\n"
MOTD_EOF

sudo chmod +x /etc/update-motd.d/00-deploymatic

# Désactive le motd-news (pub Ubuntu Pro/Canonical) pour un banner propre
if [ -f /etc/default/motd-news ]; then
    sudo sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news 2>/dev/null || true
fi

ok "MOTD DeployMatic installé (visible au prochain ssh)"

# ----- 10. Récapitulatif ----------------------------------------------------
echo
echo "═══════════════════════════════════════════════════════════"
echo "  Serveur préparé — récapitulatif"
echo "═══════════════════════════════════════════════════════════"
echo "  Hostname     : $(hostname)"
echo "  OS           : $(lsb_release -ds 2>/dev/null || uname -s)"
echo "  Kernel       : $(uname -r)"
echo "  Docker       : $(docker --version 2>/dev/null | head -c 60 || echo 'non installé')"
echo "  k3s          : $(k3s --version 2>/dev/null | head -1 || echo 'non installé')"
echo "  kubectl      : $(kubectl version --client 2>/dev/null | head -1 || echo 'non installé')"
echo "  Helm         : $(helm version --short 2>/dev/null || echo 'non installé')"
echo "  Nœuds K8s    : $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
echo "═══════════════════════════════════════════════════════════"
