#!/usr/bin/env bash
# lib/diag.sh — Commandes de diagnostic (--doctor, --logs, --cluster-info).
#
# Dépend de : ENV_FILE, ssh_remote, ui_*, load_env, variables collectées.

# ----- Helpers internes -----------------------------------------------------
_diag_require_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    ui_err "Aucune config trouvée (${ENV_FILE})"
    ui_info "Lance ./bootstrap.sh une fois pour collecter les credentials."
    exit 1
  fi
  load_env
}

_diag_remote_kubectl() {
  # Exécute kubectl sur le serveur distant avec KUBECONFIG par défaut.
  ssh_remote "${OVH_USER}@${OVH_HOST}" \
    "export KUBECONFIG=~/.kube/config && $*"
}

_diag_check() {
  # _diag_check "Label" "command to test"
  local label="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    ui_ok "${label}"
    return 0
  fi
  ui_err "${label}"
  return 1
}

# ----- --doctor : check global ---------------------------------------------
cmd_doctor() {
  _diag_require_env
  ui_step "Doctor — diagnostic global"

  local fails=0 repo="${GITHUB_USER}/${GITHUB_REPO_NAME}"

  # 1) Outils locaux
  ui_info "Outils CLI locaux :"
  local tool
  for tool in git gh ssh curl jq; do
    _diag_check "${tool}" "command -v ${tool}" || fails=$((fails + 1))
  done
  echo

  # 2) GitHub
  ui_info "GitHub :"
  _diag_check "gh authentifié" "gh auth status" || fails=$((fails + 1))
  _diag_check "Dépôt ${repo} accessible" "gh repo view '${repo}'" || fails=$((fails + 1))

  # Secrets attendus
  local expected_secrets=(DOCKERHUB_USERNAME DOCKERHUB_TOKEN OVH_HOST OVH_USER)
  if [[ "${OVH_AUTH_METHOD:-key}" == "password" ]]; then
    expected_secrets+=(OVH_PASSWORD)
  else
    expected_secrets+=(OVH_SSH_KEY)
  fi
  local present_secrets
  present_secrets=$(gh secret list --repo "$repo" 2>/dev/null | awk '{print $1}' || echo "")
  local s
  for s in "${expected_secrets[@]}"; do
    if grep -qx "$s" <<<"$present_secrets"; then
      ui_ok "secret ${s}"
    else
      ui_err "secret ${s} absent"
      fails=$((fails + 1))
    fi
  done
  echo

  # 3) SSH
  ui_info "Serveur ${OVH_USER}@${OVH_HOST} :"
  if ssh_remote -o ConnectTimeout=5 "${OVH_USER}@${OVH_HOST}" 'true' 2>/dev/null; then
    ui_ok "SSH OK"
    _diag_check "sudo NOPASSWD" \
      "ssh_remote '${OVH_USER}@${OVH_HOST}' 'sudo -n true'" || fails=$((fails + 1))
    _diag_check "k3s actif" \
      "ssh_remote '${OVH_USER}@${OVH_HOST}' 'systemctl is-active --quiet k3s'" || fails=$((fails + 1))
  else
    ui_err "SSH inaccessible"
    fails=$((fails + 1))
  fi
  echo

  # 4) Cluster
  ui_info "Cluster Kubernetes :"
  local deploys
  deploys=$(_diag_remote_kubectl "kubectl get deploy ${APP_NAME}-api ${APP_NAME}-web -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}/{.status.replicas}{\"\\n\"}{end}'" 2>/dev/null || echo "")
  if [[ -n "$deploys" ]]; then
    local line name ready
    while IFS= read -r line; do
      name="${line%%=*}"
      ready="${line#*=}"
      if [[ "$ready" =~ ^([0-9]+)/([0-9]+)$ ]] && (( BASH_REMATCH[1] == BASH_REMATCH[2] && BASH_REMATCH[2] > 0 )); then
        ui_ok "deployment/${name} : ${ready} ready"
      else
        ui_err "deployment/${name} : ${ready} ready (dégradé)"
        fails=$((fails + 1))
      fi
    done <<<"$deploys"
  else
    ui_warn "Aucun deployment trouvé (déploiement pas encore fait ?)"
  fi
  echo

  # 5) HTTP
  ui_info "Endpoints HTTP :"
  _diag_check "GET http://${OVH_HOST}/api/health" \
    "curl -fsS -m 5 'http://${OVH_HOST}/api/health'" || fails=$((fails + 1))
  _diag_check "GET http://${OVH_HOST}/" \
    "curl -fsS -m 5 -o /dev/null 'http://${OVH_HOST}/'" || fails=$((fails + 1))
  echo

  # Verdict
  if (( fails == 0 )); then
    ui_ok "Tous les checks passent — système sain."
    return 0
  fi
  ui_err "${fails} check(s) en échec — voir les ✗ ci-dessus."
  return 1
}

# ----- --logs [api|web] : tail des logs pods --------------------------------
cmd_logs() {
  local target="${1:-api}"
  case "$target" in
    api|web) ;;
    *) ui_err "Usage : --logs [api|web]"; exit 1 ;;
  esac

  _diag_require_env
  local deploy="${APP_NAME}-${target}"

  ui_info "Logs de deployment/${deploy} (Ctrl-C pour quitter)…"
  _diag_remote_kubectl "kubectl logs -l app=${deploy} --all-containers --tail=200 --follow"
}

# ----- --cluster-info : aperçu de l'état du cluster ------------------------
cmd_cluster_info() {
  _diag_require_env
  ui_step "État du cluster Kubernetes"

  local sections=(
    "NODES|kubectl get nodes -o wide"
    "PODS (tous namespaces)|kubectl get pods -A -o wide"
    "SERVICES|kubectl get svc -A"
    "INGRESS|kubectl get ingress -A"
    "DEPLOYMENTS (app)|kubectl get deploy -l 'app in (${APP_NAME}-api,${APP_NAME}-web)' -o wide 2>/dev/null || true"
  )

  local combined="" entry label cmd
  for entry in "${sections[@]}"; do
    label="${entry%%|*}"
    cmd="${entry#*|}"
    combined+="echo '=== ${label} ===' ; ${cmd} ; echo ;"
  done

  _diag_remote_kubectl "$combined"
}
