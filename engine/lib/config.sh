#!/usr/bin/env bash
# lib/config.sh — Source unique de vérité pour les variables d'env du bootstrap.
#
# Ajouter une variable = l'ajouter une seule fois à ALL_VARS, et tout suit :
#   - save_env l'écrit dans .bootstrap-env
#   - load_env / load_config_file la lisent
#   - reset_collected_vars la vide quand l'utilisateur modifie les paramètres
#
# Dépend de : ENV_FILE, ui_* helpers.

ALL_VARS=(
  GITHUB_USER
  GITHUB_REPO_NAME
  APP_AUTHOR
  DOCKERHUB_USER
  DOCKERHUB_TOKEN
  OVH_HOST
  OVH_USER
  OVH_AUTH_METHOD
  OVH_SSH_KEY_PATH
  OVH_PASSWORD
  APP_NAME
  APP_PORT
  API_PORT
  REPLICAS_API
  REPLICAS_WEB
  CPU_LIMIT_API
  MEM_LIMIT_API
  DEPLOY_ENV
  INGRESS_HOST
  ACME_EMAIL
)

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
}

load_config_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    ui_err "Fichier de config introuvable : ${file}"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$file"
  ui_ok "Config chargée depuis ${file}"
}

save_env() {
  {
    echo "# Généré automatiquement par bootstrap.sh — ne pas versionner"
    local var
    for var in "${ALL_VARS[@]}"; do
      printf '%s="%s"\n' "$var" "${!var:-}"
    done
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

reset_collected_vars() {
  local var
  for var in "${ALL_VARS[@]}"; do
    unset "$var"
  done
}
