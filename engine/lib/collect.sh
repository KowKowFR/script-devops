#!/usr/bin/env bash
# lib/collect.sh — Collecte interactive des credentials + récap + confirmation.
#
# Dépend de : PROJECT_NAME, ALL_VARS, save_env, state_*, ui_*, ensure_sshpass.

collect_credentials() {
  ui_step "Collecte des informations du projet"

  if state_has "credentials_collected"; then
    ui_skip "Credentials déjà collectés"
    return 0
  fi

  local gh_default
  gh_default=$(gh api user --jq .login 2>/dev/null || echo "")

  # Bloc 1 — Identités
  ui_prompt GITHUB_USER       "Ton username GitHub ?" "$gh_default"
  ui_prompt GITHUB_REPO_NAME  "Nom du dépôt à créer ?" "$PROJECT_NAME"
  ui_prompt APP_AUTHOR        "Nom de l'auteur (apparaît dans /info) ?" "$GITHUB_USER"
  ui_prompt DOCKERHUB_USER    "Ton username Docker Hub ?"
  ui_prompt DOCKERHUB_TOKEN   "Ton token Docker Hub (scope Read/Write/Delete)" --password

  # Bloc 2 — Infra
  ui_prompt OVH_HOST          "IP/hostname de ton serveur OVH ?"
  ui_prompt OVH_USER          "Utilisateur SSH sur le serveur ?" "devops"
  ui_choose OVH_AUTH_METHOD   "Méthode d'authentification SSH ?" "key" "key" "password"

  if [[ "$OVH_AUTH_METHOD" == "password" ]]; then
    ui_prompt OVH_PASSWORD "Mot de passe SSH de ${OVH_USER}@${OVH_HOST} ?" --password
    OVH_SSH_KEY_PATH=""
    ensure_sshpass
  else
    ui_prompt OVH_SSH_KEY_PATH "Chemin de ta clé SSH privée ?" "$HOME/.ssh/id_ed25519"
    OVH_PASSWORD=""
    if [[ ! -f "$OVH_SSH_KEY_PATH" ]]; then
      ui_err "Clé SSH introuvable : ${OVH_SSH_KEY_PATH}"
      exit 1
    fi
  fi

  # Bloc 3 — Paramètres app
  ui_prompt APP_NAME      "Nom du déploiement (manifests + images) ?" "tp-app"
  ui_prompt APP_PORT      "Port HTTP du frontend ?" "80"
  ui_prompt API_PORT      "Port HTTP de l'API ?" "3000"

  # Bloc 4 — Scaling et ressources
  ui_prompt REPLICAS_API  "Nombre de réplicas API ?" "2"
  ui_prompt REPLICAS_WEB  "Nombre de réplicas Web ?" "2"
  ui_prompt CPU_LIMIT_API "Limite CPU API ?" "200m"
  ui_prompt MEM_LIMIT_API "Limite mémoire API ?" "128Mi"

  # Bloc 5 — Environnement
  ui_choose DEPLOY_ENV       "Environnement cible ?" "dev" "dev" "staging" "prod"
  ui_prompt INGRESS_HOST     "Hostname Ingress (vide = match par IP) ?" --optional

  # Bloc 6 — TLS (Let's Encrypt via cert-manager). Nécessite un hostname public.
  if [[ -n "${INGRESS_HOST:-}" ]]; then
    ui_prompt ACME_EMAIL "Email Let's Encrypt pour TLS auto (vide = pas de TLS) ?" --optional
  else
    ACME_EMAIL=""
  fi

  save_env
  ui_ok "Credentials sauvegardés dans ${ENV_FILE} (chmod 600)"
  state_mark "credentials_collected"
}

show_summary() {
  local rows=(
    "GitHub        | ${GITHUB_USER}/${GITHUB_REPO_NAME}"
    "Auteur        | ${APP_AUTHOR}"
    "Docker Hub    | ${DOCKERHUB_USER}"
    "Serveur SSH   | ${OVH_USER}@${OVH_HOST}"
    "Auth SSH      | ${OVH_AUTH_METHOD:-key}"
    "Clé SSH       | ${OVH_SSH_KEY_PATH:-<password>}"
    "App name      | ${APP_NAME}"
    "Environnement | ${DEPLOY_ENV}"
    "Port web      | ${APP_PORT}"
    "Port API      | ${API_PORT}"
    "Réplicas API  | ${REPLICAS_API}"
    "Réplicas Web  | ${REPLICAS_WEB}"
    "CPU API       | ${CPU_LIMIT_API}"
    "RAM API       | ${MEM_LIMIT_API}"
    "Ingress host  | ${INGRESS_HOST:-<aucun>}"
    "TLS (ACME)    | ${ACME_EMAIL:-<désactivé>}"
  )
  gum_box "$C_NAVY_HEX" "Récapitulatif du bootstrap" "${rows[@]}"
}

confirm_summary() {
  while true; do
    show_summary
    if [[ "${BOOTSTRAP_NONINTERACTIVE:-0}" == "1" ]]; then
      ui_ok "Mode non-interactif : exécution sans confirmation"
      return 0
    fi
    if ui_confirm "Lancer le bootstrap avec ces paramètres ?"; then
      return 0
    fi
    ui_warn "Modification des paramètres…"
    reset_collected_vars
    state_unmark "credentials_collected"
    collect_credentials
  done
}
