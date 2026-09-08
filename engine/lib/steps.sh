#!/usr/bin/env bash
# lib/steps.sh — Les fonctions step_* exécutées par le pipeline.
#
# Convention : chaque step_* est "pure" — elle fait son travail, mais ne gère
# NI le check d'idempotence, NI l'affichage du titre. Tout ça est géré par
# run_step() dans bootstrap.sh, qui pilote l'exécution depuis PIPELINE.
#
# Dépend de : SCRIPT_DIR, WORK_DIR, ENV_FILE, ssh_remote*, ui_*, state_*,
#             toutes les variables collectées (GITHUB_USER, OVH_HOST, etc.).

# ----- 1 : validation SSH ---------------------------------------------------
step_validate_ssh() {
  ui_info "Test de connexion à ${OVH_USER}@${OVH_HOST}…"

  if ssh_remote -o ConnectTimeout=10 \
         "${OVH_USER}@${OVH_HOST}" \
         'echo "SSH OK : $(hostname) — $(lsb_release -ds 2>/dev/null || uname -s)"'; then
    ui_ok "Connexion SSH réussie"
  else
    ui_err "Connexion SSH impossible"
    cat <<EOF
Vérifie que :
  - L'IP (${OVH_HOST}) est correcte
  - L'utilisateur (${OVH_USER}) existe sur le serveur
  - Ta clé publique est dans ~/.ssh/authorized_keys du serveur
EOF
    exit 1
  fi
}

# ----- 2 : création du dossier projet ---------------------------------------
step_create_project_dir() {
  if [[ -d "$WORK_DIR" ]]; then
    if ui_confirm "${WORK_DIR} existe déjà. Le réutiliser ?"; then
      ui_ok "Réutilisation du dossier existant"
    else
      ui_err "Annulation. Supprime le dossier ou utilise --reset."
      exit 1
    fi
  else
    mkdir -p "$WORK_DIR"
    ui_ok "Dossier créé : ${WORK_DIR}"
  fi
}

# ----- 3 : génération des microservices -------------------------------------
# Note : régénérée à chaque run (overwrite idempotent). Le state_mark côté
# orchestrateur ne sert qu'au --status.
step_generate_microservices() {
  APP_NAME="$APP_NAME" \
  APP_PORT="$APP_PORT" \
  API_PORT="$API_PORT" \
    bash "$SCRIPT_DIR/lib/gen_microservices.sh" "$WORK_DIR" "$APP_AUTHOR"
  ui_ok "Microservices générés"
}

# ----- 4 : manifests K8s ----------------------------------------------------
step_generate_manifests() {
  APP_NAME="$APP_NAME" \
  APP_PORT="$APP_PORT" \
  API_PORT="$API_PORT" \
  REPLICAS_API="$REPLICAS_API" \
  REPLICAS_WEB="$REPLICAS_WEB" \
  CPU_LIMIT_API="$CPU_LIMIT_API" \
  MEM_LIMIT_API="$MEM_LIMIT_API" \
  INGRESS_HOST="$INGRESS_HOST" \
  ACME_EMAIL="${ACME_EMAIL:-}" \
    bash "$SCRIPT_DIR/lib/gen_manifests.sh" "$WORK_DIR" "$DOCKERHUB_USER"
  ui_ok "Manifests générés (k8s/base/)"
}

# ----- 5 : Skills Claude Code -----------------------------------------------
step_generate_skills() {
  bash "$SCRIPT_DIR/lib/gen_skills.sh" "$WORK_DIR"
  ui_ok "Skills générées (.agents/skills/)"
}

# ----- 6 : workflow GitHub Actions ------------------------------------------
step_generate_workflow() {
  APP_NAME="$APP_NAME" \
  OVH_AUTH_METHOD="${OVH_AUTH_METHOD:-key}" \
    bash "$SCRIPT_DIR/lib/gen_workflow.sh" "$WORK_DIR"
  ui_ok "Workflow généré (.github/workflows/deploy.yml)"
}

# ----- 7 : sudo NOPASSWD ----------------------------------------------------
step_enable_sudo_nopasswd() {
  if ssh_remote "${OVH_USER}@${OVH_HOST}" 'sudo -n true' 2>/dev/null; then
    ui_ok "sudo NOPASSWD déjà actif pour ${OVH_USER}"
    return 0
  fi

  ui_warn "L'utilisateur ${OVH_USER} a besoin de sudo NOPASSWD pour les étapes suivantes"
  ui_info "Cette commande va demander une seule fois le mot de passe sudo de ${OVH_USER}"
  ui_info "puis configurera /etc/sudoers.d/ pour les fois suivantes"

  if ! ui_confirm "Configurer sudo NOPASSWD maintenant ?"; then
    ui_err "Sans NOPASSWD, le bootstrap ne peut pas continuer (étapes suivantes en SSH non-interactif)"
    cat <<EOF
Alternative manuelle : sur le serveur, en tant que root :
  echo "${OVH_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/${OVH_USER}
  sudo chmod 440 /etc/sudoers.d/${OVH_USER}
EOF
    exit 1
  fi

  ui_info "Connexion au serveur (entre ton mot de passe sudo quand demandé)…"

  # shellcheck disable=SC2087
  ssh_remote_tty "${OVH_USER}@${OVH_HOST}" <<EOF
set -e
echo "${OVH_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/${OVH_USER}-bootstrap > /dev/null
sudo chmod 440 /etc/sudoers.d/${OVH_USER}-bootstrap
sudo visudo -c -f /etc/sudoers.d/${OVH_USER}-bootstrap || {
  sudo rm -f /etc/sudoers.d/${OVH_USER}-bootstrap
  echo "Erreur de configuration sudoers" >&2
  exit 1
}
echo "OK NOPASSWD configuré dans /etc/sudoers.d/${OVH_USER}-bootstrap"
EOF

  ui_info "Vérification du NOPASSWD…"
  if ssh_remote "${OVH_USER}@${OVH_HOST}" 'sudo -n true' 2>/dev/null; then
    ui_ok "sudo NOPASSWD opérationnel"
  else
    ui_err "NOPASSWD configuré mais ne fonctionne pas — vérifier manuellement"
    exit 1
  fi
}

# ----- 8 : préparation du serveur (k3s + dépendances) -----------------------
step_prepare_server() {
  ui_info "Vérification de k3s sur le serveur…"
  # ACME_EMAIL transmis au remote pour conditionner l'install de cert-manager.
  ssh_remote "${OVH_USER}@${OVH_HOST}" \
    "ACME_EMAIL='${ACME_EMAIL:-}' bash -s" \
    < "$SCRIPT_DIR/lib/prepare_server.sh"
  ui_ok "Serveur prêt (k3s opérationnel)"
}

# ----- 9 : récupération du kubeconfig ---------------------------------------
step_fetch_kubeconfig() {
  local kube_dir="$HOME/.kube"
  local kube_file="${kube_dir}/config-${GITHUB_REPO_NAME}"

  mkdir -p "$kube_dir"
  ui_info "Récupération du kubeconfig depuis le serveur…"

  ssh_remote "${OVH_USER}@${OVH_HOST}" "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s/127.0.0.1/${OVH_HOST}/g" \
    > "$kube_file"
  chmod 600 "$kube_file"

  ui_ok "Kubeconfig sauvegardé : ${kube_file}"
  ui_info "Pour utiliser kubectl localement : export KUBECONFIG=${kube_file}"

  if command -v kubectl >/dev/null 2>&1; then
    if KUBECONFIG="$kube_file" kubectl get nodes >/dev/null 2>&1; then
      ui_ok "kubectl fonctionne depuis ton poste"
    else
      ui_warn "kubectl ne se connecte pas (vérifie le port 6443 du serveur)"
    fi
  fi
}

# ----- (transient) : inventaire des ports déjà utilisés ---------------------
# Affichage uniquement (pas de state_mark). Une seule connexion SSH au lieu de 4.
step_list_cluster_ports() {
  local remote_script='
    export KUBECONFIG=~/.kube/config
    echo "=== SERVICES ==="
    kubectl get svc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP,PORTS:.spec.ports[*].port,TARGET:.spec.ports[*].targetPort,NODEPORT:.spec.ports[*].nodePort 2>/dev/null || echo "(indisponible)"
    echo
    echo "=== INGRESS ==="
    kubectl get ingress -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.rules[*].host,PORTS:.spec.rules[*].http.paths[*].backend.service.port.number 2>/dev/null || echo "(aucun)"
    echo
    echo "=== HOST PORTS ==="
    ss -tlnH 2>/dev/null | awk "{print \$4}" | awk -F: "{print \$NF}" | sort -un | paste -sd "," - || echo "(ss indisponible)"
    echo
    echo "=== CLUSTER SVC PORTS ==="
    kubectl get svc -A -o jsonpath="{range .items[*]}{.spec.ports[*].port}{\"\\n\"}{end}" 2>/dev/null | tr " " "\n" | sort -un
  '

  local output
  output=$(ssh_remote "${OVH_USER}@${OVH_HOST}" "$remote_script" 2>/dev/null || true)

  # Sections affichées
  awk '/^=== SERVICES ===$/{print "Services Kubernetes (ports & targetPorts) :"; next}
       /^=== INGRESS ===$/{print "\nIngress / hostnames :"; next}
       /^=== HOST PORTS ===$/{print "\nPorts TCP en écoute sur l'\''hôte :"; next}
       /^=== CLUSTER SVC PORTS ===$/{exit}
       {print}' <<<"$output" | sed 's/^/  /'

  echo
  ui_info "Ports applicatifs ciblés par CE bootstrap : web=${APP_PORT}  api=${API_PORT}"

  # Détection de conflit
  local cluster_ports
  cluster_ports=$(awk '/^=== CLUSTER SVC PORTS ===$/{flag=1; next} flag' <<<"$output")
  local p
  for p in "$APP_PORT" "$API_PORT"; do
    if grep -qx "$p" <<<"$cluster_ports"; then
      ui_warn "Le port ${p} est DÉJÀ utilisé par un Service du cluster"
    else
      ui_ok "Port ${p} libre côté Services cluster"
    fi
  done
}

# ----- 10 : application initiale des manifests ------------------------------
step_apply_initial_manifests() {
  ui_info "Copie des manifests sur le serveur…"
  scp_remote -r "$WORK_DIR/k8s" \
    "${OVH_USER}@${OVH_HOST}:~/tp-k8s-manifests-initial"

  ui_info "Application des manifests via kubectl…"
  ssh_remote "${OVH_USER}@${OVH_HOST}" \
    'export KUBECONFIG=~/.kube/config && kubectl apply -f ~/tp-k8s-manifests-initial/base/'
  ui_ok "Deployments et Ingress créés"
}

# ----- 11 : création du dépôt GitHub ----------------------------------------
step_create_github_repo() {
  local repo="${GITHUB_USER}/${GITHUB_REPO_NAME}"

  if gh repo view "$repo" >/dev/null 2>&1; then
    ui_warn "Le dépôt ${repo} existe déjà"
    if ! ui_confirm "Continuer avec ce dépôt existant ?"; then
      ui_err "Annulation"
      exit 1
    fi
    return 0
  fi

  ui_info "Création de ${repo} (public)…"
  gh repo create "$repo" --public \
    --description "TP DevSecOps — chaîne automatisée pilotée par Skills Claude Code"
  ui_ok "Dépôt créé : https://github.com/${repo}"
}

# ----- 12 : secrets GitHub Actions ------------------------------------------
step_set_github_secrets() {
  local repo="${GITHUB_USER}/${GITHUB_REPO_NAME}"
  ui_info "Ajout des secrets dans ${repo}…"

  # Secrets communs
  local name value
  for entry in \
    "DOCKERHUB_USERNAME=${DOCKERHUB_USER}" \
    "DOCKERHUB_TOKEN=${DOCKERHUB_TOKEN}" \
    "OVH_HOST=${OVH_HOST}" \
    "OVH_USER=${OVH_USER}"
  do
    name="${entry%%=*}"
    value="${entry#*=}"
    gh secret set "$name" --repo "$repo" --body "$value" && ui_ok "$name"
  done

  # Auth-spécifique
  if [[ "${OVH_AUTH_METHOD:-key}" == "password" ]]; then
    gh secret set OVH_PASSWORD --repo "$repo" --body "$OVH_PASSWORD" \
      && ui_ok "OVH_PASSWORD (la CI utilisera sshpass)"
  else
    _upload_ssh_key_secret "$repo" "$OVH_SSH_KEY_PATH" \
      && ui_ok "OVH_SSH_KEY"
  fi
}

# Upload une clé SSH en garantissant un trailing newline (sinon "error in
# libcrypto" + "Permission denied" côté runner GitHub).
_upload_ssh_key_secret() {
  local repo="$1" key_path="$2" tmp rc=0
  if ! ssh-keygen -y -f "$key_path" >/dev/null 2>&1; then
    ui_err "Clé SSH invalide ou protégée par passphrase : ${key_path}"
    ui_info "Une clé chiffrée par passphrase ne peut pas être utilisée par la CI."
    exit 1
  fi
  # Cleanup explicite (pas de `trap RETURN` : il fuiterait au caller frame).
  tmp=$(mktemp)
  cat "$key_path" > "$tmp"
  [[ -z "$(tail -c1 "$tmp")" ]] || printf '\n' >> "$tmp"
  gh secret set OVH_SSH_KEY --repo "$repo" < "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# ----- 13 : init Git --------------------------------------------------------
step_init_git() {
  (
    cd "$WORK_DIR"

    if [[ ! -d .git ]]; then
      git init -q -b main
      ui_ok "git init (branche main)"
    fi

    cat > .gitignore <<'EOF'
# Bootstrap state (ne jamais versionner les credentials)
.bootstrap-state
.bootstrap-env

# Node
node_modules/
npm-debug.log

# Local kubeconfig
.kube/

# OS
.DS_Store
Thumbs.db

# IDE
.vscode/
.idea/

# Logs
*.log
EOF

    git remote add origin "https://github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}.git" 2>/dev/null \
      || git remote set-url origin "https://github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}.git"

    ui_ok "Remote origin configuré"
  )
}

# ----- 14 : push initial ----------------------------------------------------
step_push_to_github() {
  (
    cd "$WORK_DIR"

    git add .
    if git diff --cached --quiet; then
      ui_info "Aucun changement à commiter"
    else
      git -c user.email="${GITHUB_USER}@users.noreply.github.com" \
          -c user.name="${GITHUB_USER}" \
          commit -m "chore: initial bootstrap by bootstrap.sh

- Microservices API (Express) + Web (nginx)
- Manifests Kubernetes (deployments + ingress)
- Skills Claude Code custom (4)
- Pipeline CI/CD GitHub Actions
" -q
      ui_ok "Commit initial créé"
    fi

    ui_info "Push vers origin/main…"
    git push -u origin main
    ui_ok "Push réussi"
  )
}

# ----- 15 : déclenchement du premier déploiement ----------------------------
step_trigger_first_deploy() {
  local repo="${GITHUB_USER}/${GITHUB_REPO_NAME}"

  ui_info "Le push précédent a déjà déclenché le workflow."
  ui_info "Suivi en direct : https://github.com/${repo}/actions"
  ui_info "Attente de la fin du workflow (timeout 10 min)…"

  if ui_spin "Suivi en temps réel du workflow…" -- bash -c "
    repo='${repo}'
    start_time=\$(date +%s)
    max_wait=600
    while true; do
      status=\$(gh run list --repo \"\$repo\" --limit 1 --json status,conclusion --jq '.[0]' 2>/dev/null || echo '{}')
      s=\$(echo \"\$status\" | jq -r '.status // \"unknown\"')
      c=\$(echo \"\$status\" | jq -r '.conclusion // \"\"')
      elapsed=\$(( \$(date +%s) - start_time ))
      echo \"  workflow \$s (\${elapsed}s)\"
      case \"\$s\" in
        completed)
          [[ \"\$c\" == \"success\" ]] && exit 0
          echo \"workflow conclusion: \$c\"
          exit 1
          ;;
      esac
      if (( elapsed > max_wait )); then echo timeout; exit 1; fi
      sleep 10
    done
  "; then
    ui_ok "Workflow terminé avec succès"
  else
    ui_err "Workflow échoué ou timeout"
    ui_info "Logs : gh run view --repo ${repo} --log"
    exit 1
  fi
}

# ----- 16 : validation finale -----------------------------------------------
step_validate_deployment() {
  ui_info "Test de l'endpoint /api/health…"

  local url="http://${OVH_HOST}/api/health" response http_code i
  for i in {1..10}; do
    if response=$(curl -fsS -m 5 "$url" 2>/dev/null); then
      http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
      ui_ok "API répond : ${url} → ${http_code}"
      printf "%b\n" "${C_DIM}     ${response}${C_RESET}"
      break
    fi
    ui_info "Tentative ${i}/10… (les pods démarrent)"
    sleep 6
    if (( i == 10 )); then
      ui_err "L'API ne répond pas après 60 s"
      ui_info "Diagnostic : ssh ${OVH_USER}@${OVH_HOST} 'kubectl get pods'"
      exit 1
    fi
  done

  ui_info "Test du frontend…"
  if curl -fsS -m 5 -o /dev/null "http://${OVH_HOST}/"; then
    ui_ok "Frontend répond : http://${OVH_HOST}/"
  else
    ui_warn "Frontend pas encore prêt"
  fi
}

# ----- Affichages finaux ----------------------------------------------------
print_success() {
  local body=(
    "🌍 Application :  http://${OVH_HOST}"
    "⚙  API :          http://${OVH_HOST}/api/"
    "♡  Health :       http://${OVH_HOST}/api/health"
    "⎇  Dépôt :        https://github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}"
    "⚒  CI/CD :        https://github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}/actions"
    ""
    "App         : ${APP_NAME} (${DEPLOY_ENV})"
    "Réplicas    : API=${REPLICAS_API}  Web=${REPLICAS_WEB}"
    "Ressources  : ${CPU_LIMIT_API} CPU / ${MEM_LIMIT_API} RAM (API)"
    ""
    "Pour piloter via Claude Code :"
    "  cd ${WORK_DIR}"
    "  claude"
    "  > \"Ajoute une route /stats dans l'API, déploie, vérifie la santé\""
    ""
    "Pour reset  : ./bootstrap.sh --reset"
    "Pour status : ./bootstrap.sh --status"
  )
  gum_box "$C_GREEN_HEX" "OK  BOOTSTRAP TERMINÉ — TOUT EST EN PROD" "${body[@]}"
}

show_banner() {
  # Logo DeployMatic en gros ASCII (ANSI Shadow), empilé sur 2 mots
  # (DEPLOY / MATIC) → ~50 colonnes, rentre dans tous les terminaux.
  # Fallback gum_box uniquement pour les terminaux vraiment étroits (< 52).
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  if (( cols < 52 )); then
    gum_box "$C_NAVY_HEX" \
      "DeployMatic" \
      "Chaîne DevSecOps automatisée"
    return 0
  fi

  printf '%b' "${C_NAVY}${C_BOLD}"
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
  printf '%b' "${C_RESET}"
  printf "  ${C_CORAL}${C_BOLD}Chaîne DevSecOps automatisée${C_RESET}\n"
  printf "  ${C_DIM}k3s + GitHub Actions + Skills Claude Code — en un seul script${C_RESET}\n\n"
}
