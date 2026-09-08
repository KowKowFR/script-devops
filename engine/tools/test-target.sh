#!/usr/bin/env bash
# engine/tools/test-target.sh — cible SSH Ubuntu locale pour tester l'engine.
#
# POURQUOI CE SCRIPT
# L'engine déploie sur une machine Ubuntu distante via SSH (lib/prepare_server.sh,
# lib/steps.sh). Aucune cible n'a jamais été disponible pour l'exercer pour de
# vrai : ni apt-get, ni systemctl enable --now, ni ufw, ni fail2ban, ni le sudo
# NOPASSWD qu'exige step_enable_sudo_nopasswd. Ce script fournit cette cible,
# localement, en une commande — et la détruit tout aussi facilement.
#
# POURQUOI LIMA ET PAS UN CONTENEUR
# prepare_server.sh appelle `systemctl enable --now`, installe docker-ce depuis
# le dépôt officiel, configure ufw et fail2ban. Un conteneur sans systemd ne
# peut pas jouer ce rôle fidèlement : on obtiendrait des faux positifs. Une VM
# Ubuntu 24.04 avec systemd (via Lima, qui ne demande pas de mot de passe admin
# à l'installation et fournit `vz`, le driver de virtualisation natif macOS)
# est le bon niveau de fidélité.
#
# POURQUOI UN ALIAS SSH ET PAS UN PORT DANS env.json
# lib/ssh_remote.sh construit toujours `ssh -i "$OVH_SSH_KEY_PATH" ... "user@host"`
# sans jamais passer -p : le champ target.host d'env.json n'a pas de place pour
# un port. Comme Lima expose la VM via un port localhost non standard (sans
# privilège root, on ne peut pas se lier au port 22 sur l'hôte — testé, EACCES),
# la seule façon de rester compatible avec l'engine SANS le modifier est de
# déclarer un alias dans ~/.ssh/config (bloc `Host …` avec `Port …`) et d'utiliser
# cet alias comme `target.host`. OpenSSH résout le port tout seul. C'est ce que
# fait `sync_ssh_alias` ci-dessous, en préfixant ~/.ssh/config d'un `Include`
# vers un fichier propre au projet (jamais d'édition en dur du fichier de
# l'utilisateur).
#
# COMPATIBILITÉ : bash 3.2 (celui de macOS). Pas de `declare -A`, pas de
# `${var,,}`, pas de `mapfile`.

set -euo pipefail

# ----- Chemins ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT

# Tout ce que ce script produit (clé, config Lima, alias SSH) vit ici. Un seul
# dossier à supprimer pour repartir de zéro (en plus de `down`).
readonly STATE_DIR="${REPO_ROOT}/.test-target"
readonly KEY_PATH="${STATE_DIR}/id_ed25519"
readonly PUB_PATH="${KEY_PATH}.pub"
readonly LIMA_YAML="${STATE_DIR}/lima.yaml"
readonly SSH_SNIPPET="${STATE_DIR}/ssh_config"
readonly KNOWN_HOSTS="${STATE_DIR}/known_hosts"

readonly VM_NAME="deploymatic-test-target"
readonly VM_USER="devops"
readonly SSH_ALIAS="deploymatic-test-target"
readonly DEFAULT_SSH_PORT=60122
readonly SSH_INCLUDE_MARK="# BEGIN deploymatic-test-target (géré par engine/tools/test-target.sh, ne pas éditer)"
readonly SSH_INCLUDE_MARK_END="# END deploymatic-test-target"

readonly SPEC_DEMO="${REPO_ROOT}/engine/templates/spec.demo.json"

# ----- Affichage (stderr uniquement — stdout reste propre pour `env`) --------
C_GREEN='\033[38;5;35m'; C_RED='\033[38;5;160m'; C_BLUE='\033[38;5;39m'
C_YELLOW='\033[38;5;214m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
log()  { printf '%b\n' "${C_BLUE}ℹ${C_RESET}  $*" >&2; }
ok()   { printf '%b\n' "${C_GREEN}✓${C_RESET}  $*" >&2; }
warn() { printf '%b\n' "${C_YELLOW}⚠${C_RESET}  $*" >&2; }
err()  { printf '%b\n' "${C_RED}✗${C_RESET}  $*" >&2; }
die()  { err "$*"; exit 1; }

# ----- Prérequis ---------------------------------------------------------------

# S'assure que limactl est disponible. L'installe via brew si absent (pas de
# mot de passe admin requis pour `brew install lima` — vérifié). Si brew
# lui-même est absent, on explique plutôt que d'improviser.
ensure_lima() {
  if command -v limactl >/dev/null 2>&1; then
    return 0
  fi
  warn "Lima (limactl) n'est pas installé."
  if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew introuvable. Installe Homebrew (https://brew.sh) puis relance, ou installe Lima manuellement : https://lima-vm.io/docs/installation/"
  fi
  log "Installation de Lima via Homebrew (brew install lima)…"
  brew install lima
  command -v limactl >/dev/null 2>&1 || die "Lima installé mais 'limactl' introuvable dans le PATH"
  ok "Lima installé ($(limactl --version))"
}

command -v jq >/dev/null 2>&1 || die "jq est requis (brew install jq)"

# ----- Clé SSH dédiée ----------------------------------------------------------

# Génère une clé ed25519 dédiée à la cible de test, SANS passphrase (le CI en
# a besoin pour un usage non interactif). Jamais la clé personnelle de
# l'utilisateur — ce serait un désastre de sécurité et une fuite entre projets.
ensure_key() {
  mkdir -p "$STATE_DIR"
  if [[ -f "$KEY_PATH" && -f "$PUB_PATH" ]]; then
    return 0
  fi
  log "Génération d'une clé SSH dédiée (${KEY_PATH})…"
  ssh-keygen -t ed25519 -N "" -C "deploymatic-test-target" -f "$KEY_PATH" -q
  chmod 600 "$KEY_PATH"
  chmod 644 "$PUB_PATH"
  ok "Clé générée"
}

# ----- Génération du fichier Lima -----------------------------------------------

# Écrit .test-target/lima.yaml. Régénéré à chaque `up` (idempotent : le contenu
# ne change que si la clé publique change, ce qui n'arrive jamais après le
# premier `up`). La clé publique de devops est injectée directement dans le
# script de provisioning "system" (exécuté en root à chaque démarrage de la VM
# par Lima — d'où le soin d'idempotence dans le script lui-même : `id -u`,
# `grep -qxF`, sudoers réécrit sans jamais dupliquer).
render_lima_yaml() {
  local pubkey
  pubkey="$(cat "$PUB_PATH")"

  # `base: [template:_images/ubuntu-24.04]` réutilise le catalogue d'images
  # Ubuntu 24.04 fourni par Lima (URLs + empreintes officielles, multi-arch) au
  # lieu de coder une URL en dur ici — Lima les tient à jour à notre place.
  cat > "$LIMA_YAML" <<'YAML_HEAD'
# Généré par engine/tools/test-target.sh — NE PAS ÉDITER À LA MAIN.
# Régénéré (écrasé) à chaque `up`.
base:
- template:_images/ubuntu-24.04

vmType: "vz"
cpus: 2
memory: "4GiB"
disk: "20GiB"

# Pas de partage de dossier : la cible n'a besoin de rien du Mac.
mounts: []

# Ni containerd/nerdctl côté Lima : on ne teste QUE ce que prepare_server.sh
# installe lui-même (docker-ce). Le containerd rootless de Lima déclenche un
# `containerd-rootless-setuptool.sh install` pour l'utilisateur par défaut —
# lent, dépendant du réseau, et observé bloqué plusieurs minutes en pratique.
# Aucune utilité ici : on le désactive entièrement.
containerd:
  system: false
  user: false

ssh:
  loadDotSSHPubKeys: false

provision:
- mode: system
  script: |
    #!/bin/bash
    set -eux -o pipefail

    # Utilisateur devops, dédié aux tests de l'engine DeployMatic.
    id -u devops >/dev/null 2>&1 || useradd -m -s /bin/bash devops

    install -d -m 700 -o devops -g devops /home/devops/.ssh
    AUTH=/home/devops/.ssh/authorized_keys
    touch "$AUTH"
    grep -qxF "__DEVOPS_PUBKEY__" "$AUTH" || echo "__DEVOPS_PUBKEY__" >> "$AUTH"
    chmod 600 "$AUTH"
    chown devops:devops "$AUTH"

    # sudo NOPASSWD : l'engine ne sait pas le configurer sans TTY (voir
    # step_enable_sudo_nopasswd dans lib/steps.sh, qui échoue exprès en code 2
    # avec des instructions manuelles) — la cible de test doit l'avoir d'emblée.
    SUDOFILE=/etc/sudoers.d/90-devops-test-target
    echo "devops ALL=(ALL) NOPASSWD:ALL" > "$SUDOFILE"
    chmod 440 "$SUDOFILE"
    visudo -c -f "$SUDOFILE"

    # Docker doit être ABSENT au démarrage : prepare_server.sh doit avoir un
    # vrai travail à faire (installation depuis le dépôt officiel), sinon on ne
    # teste rien du jalon 1. On le retire si l'image de base l'embarquait.
    if command -v docker >/dev/null 2>&1 || dpkg -l 2>/dev/null | grep -q '^ii  docker'; then
      apt-get remove -y -qq docker.io docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin moby-engine podman-docker >/dev/null 2>&1 || true
      apt-get autoremove -y -qq >/dev/null 2>&1 || true
      rm -rf /var/lib/docker /etc/docker
    fi
YAML_HEAD

  # Substitution littérale (pas d'interpolation shell) : une clé publique
  # ed25519 ne contient que [A-Za-z0-9+/=] et un commentaire sans espace
  # problématique, donc sûre comme motif ET comme remplacement pour `sed`.
  # Le délimiteur `|` évite le conflit avec les `/` du base64.
  sed -i.bak "s|__DEVOPS_PUBKEY__|${pubkey}|g" "$LIMA_YAML"
  rm -f "${LIMA_YAML}.bak"
}

# ----- État de la VM -------------------------------------------------------

# Renvoie sur stdout le JSON `limactl list` pour notre instance, ou rien si
# elle n'existe pas encore.
lima_instance_json() {
  limactl list --json 2>/dev/null | jq -c --arg n "$VM_NAME" 'select(.name == $n)' || true
}

vm_exists() { [[ -n "$(lima_instance_json)" ]]; }

vm_status() {
  local j
  j="$(lima_instance_json)"
  if [[ -z "$j" ]]; then printf 'absente'; return; fi
  jq -r '.status' <<<"$j"
}

vm_ssh_port() {
  local j
  j="$(lima_instance_json)"
  [[ -n "$j" ]] || { printf ''; return; }
  jq -r '.sshLocalPort // empty' <<<"$j"
}

# ----- Alias SSH (~/.ssh/config) --------------------------------------------

# Écrit .test-target/ssh_config (Host deploymatic-test-target → 127.0.0.1:PORT)
# et s'assure que ~/.ssh/config l'inclut. Nécessaire car lib/ssh_remote.sh ne
# passe jamais -p : voir le commentaire d'en-tête du fichier.
sync_ssh_alias() {
  local port="$1"

  # La VM peut avoir été détruite puis recréée (down/up, ou VM effacée à la
  # main) : sa clé d'hôte change alors, mais l'ancienne traîne dans notre
  # known_hosts pour ce même 127.0.0.1:PORT. Sans purge, StrictHostKeyChecking
  # accept-new refuse la nouvelle clé (conflit, pas une simple absence) et
  # bloque toute connexion. Purge inconditionnelle avant chaque sync : notre
  # known_hosts ne sert qu'à cette VM jetable, pas d'enjeu de sécurité réel.
  touch "$KNOWN_HOSTS"
  ssh-keygen -R "[127.0.0.1]:${port}" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true

  cat > "$SSH_SNIPPET" <<EOF
# Généré par engine/tools/test-target.sh — NE PAS ÉDITER À LA MAIN.
Host ${SSH_ALIAS}
    HostName 127.0.0.1
    Port ${port}
    User ${VM_USER}
    IdentityFile ${KEY_PATH}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ${KNOWN_HOSTS}
EOF

  local ssh_cfg="${HOME}/.ssh/config"
  mkdir -p "${HOME}/.ssh"
  touch "$ssh_cfg"
  chmod 600 "$ssh_cfg"

  if grep -qF "Include ${SSH_SNIPPET}" "$ssh_cfg" 2>/dev/null; then
    return 0
  fi

  log "Ajout d'un Include dans ~/.ssh/config (bloc marqué, réversible)…"
  # Prépendu en tête : un `Host *` déjà présent plus haut dans le fichier de
  # l'utilisateur gagnerait sinon (OpenSSH retient la première valeur vue par
  # mot-clé, à travers tout le fichier effectif, Include compris).
  local tmp
  tmp="$(mktemp)"
  {
    printf '%s\n' "$SSH_INCLUDE_MARK"
    printf 'Include %s\n' "$SSH_SNIPPET"
    printf '%s\n' "$SSH_INCLUDE_MARK_END"
    printf '\n'
    cat "$ssh_cfg"
  } > "$tmp"
  mv "$tmp" "$ssh_cfg"
  chmod 600 "$ssh_cfg"
  ok "Alias SSH '${SSH_ALIAS}' enregistré"
}

# ----- Sous-commandes --------------------------------------------------------

cmd_up() {
  local start_ts elapsed port existing_status
  start_ts=$(date +%s)

  ensure_lima
  ensure_key
  render_lima_yaml

  if vm_exists; then
    existing_status="$(vm_status)"
    if [[ "$existing_status" == "Running" ]]; then
      ok "VM '${VM_NAME}' déjà démarrée — idempotent, rien à refaire"
    else
      log "VM '${VM_NAME}' existe mais est arrêtée (${existing_status}) — démarrage…"
      limactl start "$VM_NAME" -y
      ok "VM redémarrée"
    fi
  else
    log "Création de la VM '${VM_NAME}' (Ubuntu 24.04, systemd, ~1-2 min, image téléchargée au premier lancement)…"
    limactl start --name="$VM_NAME" --ssh-port="$DEFAULT_SSH_PORT" -y "$LIMA_YAML"
    ok "VM créée et démarrée"
  fi

  port="$(vm_ssh_port)"
  [[ -n "$port" ]] || die "impossible de déterminer le port SSH local de la VM"
  sync_ssh_alias "$port"

  elapsed=$(( $(date +%s) - start_ts ))
  echo >&2
  ok "Cible de test prête en ${elapsed}s"
  printf '%b\n' "  ${C_BOLD}Host${C_RESET}  : ${SSH_ALIAS}  (127.0.0.1:${port})" >&2
  printf '%b\n' "  ${C_BOLD}User${C_RESET}  : ${VM_USER}" >&2
  printf '%b\n' "  ${C_BOLD}Clé${C_RESET}   : ${KEY_PATH}" >&2
  printf '%b\n' "  ${C_BOLD}Test${C_RESET}  : ssh -i ${KEY_PATH} ${VM_USER}@${SSH_ALIAS}" >&2
}

cmd_down() {
  if ! vm_exists; then
    ok "Aucune VM '${VM_NAME}' à détruire (déjà absente)"
    return 0
  fi
  log "Destruction de la VM '${VM_NAME}'…"
  limactl delete --force "$VM_NAME"
  ok "VM détruite"
  warn "La clé SSH et l'alias ~/.ssh/config sont conservés (relance 'up' pour recréer la VM avec la même clé)."
  warn "Pour tout supprimer : rm -rf '${STATE_DIR}' et retire le bloc marqué dans ~/.ssh/config."
}

cmd_status() {
  if ! vm_exists; then
    printf 'absente\n'
    log "Aucune VM '${VM_NAME}'. Lance : engine/tools/test-target.sh up"
    return 0
  fi
  local status port
  status="$(vm_status)"
  port="$(vm_ssh_port)"
  printf '%s\n' "$status"
  printf '%b\n' "  ${C_BOLD}Host${C_RESET}  : ${SSH_ALIAS}  (127.0.0.1:${port:-?})" >&2
  printf '%b\n' "  ${C_BOLD}User${C_RESET}  : ${VM_USER}" >&2
  printf '%b\n' "  ${C_BOLD}Clé${C_RESET}   : ${KEY_PATH}" >&2
}

cmd_env() {
  vm_exists || die "aucune VM '${VM_NAME}' — lance d'abord : engine/tools/test-target.sh up"
  [[ "$(vm_status)" == "Running" ]] || die "VM '${VM_NAME}' pas démarrée — lance : engine/tools/test-target.sh up"

  local port app_name
  port="$(vm_ssh_port)"
  sync_ssh_alias "$port" >/dev/null 2>&1 || true

  [[ -f "$SPEC_DEMO" ]] || die "introuvable : ${SPEC_DEMO}"
  app_name="$(jq -r '.name' "$SPEC_DEMO")"
  [[ -n "$app_name" && "$app_name" != "null" ]] || die "spec.demo.json : champ .name absent ou vide"

  jq -n \
    --arg app_name "$app_name" \
    --arg host "$SSH_ALIAS" \
    --arg user "$VM_USER" \
    --arg key_path "$KEY_PATH" \
    '{
      app:      { name: $app_name, author: "Test" },
      target:   { host: $host, user: $user, auth_method: "key",
                  ssh_key_path: $key_path, password: "", bind_addr: "0.0.0.0" },
      registry: { user: "", token: "" },
      github:   { enabled: false, user: "", repo: "", token: "" },
      ports:    { api: 10001, web: 10002 },
      limits:   { cpu: "200m", memory: "128Mi" },
      options:  { reuse_existing_dir: true, allow_existing_repo: true }
    }'
}

cmd_ssh() {
  vm_exists || die "aucune VM '${VM_NAME}' — lance d'abord : engine/tools/test-target.sh up"
  local port
  port="$(vm_ssh_port)"
  [[ -n "$port" ]] || die "VM pas démarrée — lance : engine/tools/test-target.sh up"
  sync_ssh_alias "$port"
  exec ssh -i "$KEY_PATH" \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o StrictHostKeyChecking=accept-new \
    -p "$port" "${VM_USER}@127.0.0.1"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <commande>

Commandes :
  up       Crée (ou redémarre) la cible de test. Idempotent.
  down     Détruit la VM.
  status   Affiche l'état de la VM et ses coordonnées.
  env      Imprime sur stdout un env.json prêt pour runs/<ws>/env.json.
  ssh      Ouvre une session SSH interactive sur la cible.

Exemples :
  $(basename "$0") up
  $(basename "$0") env > runs/testvm/env.json
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    env)    cmd_env ;;
    ssh)    cmd_ssh ;;
    -h|--help|help|"") usage; [[ "$cmd" == "" ]] && exit 2; exit 0 ;;
    *) err "commande inconnue : ${cmd}"; usage; exit 2 ;;
  esac
}

main "$@"
