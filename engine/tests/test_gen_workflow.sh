#!/usr/bin/env bash
# engine/tests/test_gen_workflow.sh — vérifie le workflow CI/CD généré
# (lib/gen_workflow.sh) : YAML valide, aucun vestige Kubernetes, réécriture
# d'IMAGE_TAG, déploiement par docker compose, contrôle de santé par SSH sur
# 127.0.0.1 (jamais une URL publique), et les deux modes d'authentification.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SPEC_FIX="$TESTS_DIR/fixtures/spec.multi.json"

# env.json minimal : seuls les ports comptent pour gen_workflow.sh (contrôle
# de santé), le reste est ignoré par ce générateur.
ENV_FIX="$WORK/env.json"
cat > "$ENV_FIX" <<'EOF'
{ "ports": { "api": 10001, "web": 10002 } }
EOF

# _gen_workflow OUT_DIR AUTH_METHOD — exécute gen_workflow.sh dans un process
# séparé (comme test_gen_compose.sh) et renvoie son code de sortie.
_gen_workflow() {
  local out="$1" auth="$2"
  APP_NAME="demo-app" TARGET_AUTH_METHOD="$auth" SPEC_JSON="$SPEC_FIX" ENV_JSON="$ENV_FIX" \
    bash "$ENGINE_DIR/lib/gen_workflow.sh" "$out" >/dev/null 2>&1
  printf '%s' "$?"
}

# ==========================================================================
# Mode clé (défaut)
# ==========================================================================
KEY_DIR="$WORK/key"
rc_key=$(_gen_workflow "$KEY_DIR" "key")
assert_eq "0" "$rc_key" "mode clé : gen_workflow.sh réussit"

WF_KEY="$KEY_DIR/.github/workflows/deploy.yml"
assert_eq "1" "$([[ -f "$WF_KEY" ]] && echo 1 || echo 0)" "mode clé : deploy.yml est créé"

# --- Preuve 2 : YAML strictement valide (PyYAML) ---------------------------
assert_exit_code 0 "mode clé : deploy.yml généré est du YAML valide (PyYAML)" -- \
  python3 -c "import yaml; yaml.safe_load(open('$WF_KEY'))"

body_key=$(cat "$WF_KEY")

# --- Preuve 3 : plus aucun vestige Kubernetes/OVH ---------------------------
kube_count=$(grep -c 'kubectl\|KUBECONFIG\|k8s/base\|OVH_' "$WF_KEY" || true)
assert_eq "0" "$kube_count" \
  "mode clé : aucune occurrence de kubectl/KUBECONFIG/k8s base/OVH_ dans le workflow"

# --- Preuve 4 : réécriture d'IMAGE_TAG, docker compose up -d, contrôle SSH -
assert_contains "$body_key" "IMAGE_TAG=\${{ github.sha }}" \
  "mode clé : IMAGE_TAG est réécrit avec le SHA du commit"
assert_contains "$body_key" "docker compose up -d --remove-orphans" \
  "mode clé : le déploiement lance docker compose up -d"
assert_contains "$body_key" "docker compose pull" \
  "mode clé : le déploiement lance docker compose pull"

# Le contrôle de santé cible 127.0.0.1 (jamais une URL publique), construit
# depuis spec.json (services exposés + health) et env.json (ports hôte).
assert_contains "$body_key" "curl -fsS -m 5 -o /dev/null http://127.0.0.1:10001/health" \
  "mode clé : contrôle de santé de l'api sur 127.0.0.1:<port hôte>"
assert_contains "$body_key" "curl -fsS -m 5 -o /dev/null http://127.0.0.1:10002/" \
  "mode clé : contrôle de santé du web sur 127.0.0.1:<port hôte>"
assert_not_contains "$body_key" 'secrets.TARGET_HOST }}/api/health' \
  "mode clé : le contrôle de santé ne joint jamais une URL publique"

# Le contrôle de santé applicatif passe bien PAR SSH (ssh -i ~/.ssh/deploy_key
# vers l'hôte cible), pas par un accès direct depuis le runner.
health_block=$(awk '/Contrôle de santé applicatif/{f=1; next} f && /^      - name:/{exit} f{print}' "$WF_KEY")
assert_contains "$health_block" "ssh -i ~/.ssh/deploy_key" \
  "mode clé : le contrôle de santé s'exécute via SSH sur la cible"

# Rollback : restauration du tag précédent en cas d'échec
assert_contains "$body_key" ".env.prev" "mode clé : le tag précédent est sauvegardé (.env.prev)"
assert_contains "$body_key" "rollback effectué vers le tag précédent" \
  "mode clé : un rollback restaure le tag précédent en cas d'échec"

# Secrets renommés en TARGET_* (cohérents avec step_github_set_secrets)
assert_contains "$body_key" "secrets.TARGET_HOST" "mode clé : secret TARGET_HOST utilisé"
assert_contains "$body_key" "secrets.TARGET_USER" "mode clé : secret TARGET_USER utilisé"
assert_contains "$body_key" "secrets.TARGET_SSH_KEY" "mode clé : secret TARGET_SSH_KEY utilisé"
assert_not_contains "$body_key" "OVH_HOST" "mode clé : plus de secret OVH_HOST"
assert_not_contains "$body_key" "OVH_USER" "mode clé : plus de secret OVH_USER"
assert_not_contains "$body_key" "OVH_SSH_KEY" "mode clé : plus de secret OVH_SSH_KEY"

# Chemins de build alignés sur services/ (task 9), plus microservices/
assert_contains "$body_key" "context: ./services/api" "mode clé : contexte de build api = services/api"
assert_contains "$body_key" "context: ./services/web" "mode clé : contexte de build web = services/web"
assert_not_contains "$body_key" "microservices/" "mode clé : plus aucune référence à microservices/"

# ==========================================================================
# Mode mot de passe
# ==========================================================================
PW_DIR="$WORK/password"
rc_pw=$(_gen_workflow "$PW_DIR" "password")
assert_eq "0" "$rc_pw" "mode mot de passe : gen_workflow.sh réussit"

WF_PW="$PW_DIR/.github/workflows/deploy.yml"
assert_exit_code 0 "mode mot de passe : deploy.yml généré est du YAML valide (PyYAML)" -- \
  python3 -c "import yaml; yaml.safe_load(open('$WF_PW'))"

body_pw=$(cat "$WF_PW")
kube_count_pw=$(grep -c 'kubectl\|KUBECONFIG\|k8s/base\|OVH_' "$WF_PW" || true)
assert_eq "0" "$kube_count_pw" \
  "mode mot de passe : aucune occurrence de kubectl/KUBECONFIG/k8s base/OVH_ dans le workflow"

assert_contains "$body_pw" "secrets.TARGET_PASSWORD" "mode mot de passe : secret TARGET_PASSWORD utilisé"
assert_contains "$body_pw" "sshpass -e ssh" "mode mot de passe : ssh passe par sshpass"
assert_not_contains "$body_pw" "TARGET_SSH_KEY" \
  "mode mot de passe : pas de secret TARGET_SSH_KEY (pas pertinent dans ce mode)"

# Preuve 5 : les deux modes diffèrent réellement (pas de générateur qui
# ignorerait silencieusement TARGET_AUTH_METHOD) mais produisent tous deux du
# YAML valide, déjà vérifié ci-dessus pour chacun.
if [[ "$body_key" != "$body_pw" ]]; then
  _t_ok "les deux modes d'authentification (clé/mot de passe) produisent des workflows différents"
else
  _t_fail "les deux modes d'authentification (clé/mot de passe) produisent des workflows différents" \
    "les deux fichiers générés sont identiques"
fi

finish
