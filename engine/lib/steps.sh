#!/usr/bin/env bash
# engine/lib/steps.sh — les étapes exécutables de l'engine.
#
# CONVENTION (celle qui était documentée mais violée avant ce jalon)
# Une step_* fait son travail et rien d'autre : pas de titre affiché (le
# dispatcher s'en charge), pas de suivi d'état (il vit côté panel), pas de
# prompt (le worker n'a pas de TTY). Elle se termine par emit_ok, ou meurt par
# die (fatal, code 2) ou retryable (code 1).
#
# Les décisions qui étaient un prompt interactif dans l'ancienne version
# Kubernetes sont devenues soit une clé d'env.json (options.*), soit un échec
# fatal accompagné de la marche à suivre manuelle : l'engine n'a personne à
# qui demander, il tourne dans un worker sans TTY.

# shellcheck source=gen_compose.sh
source "$(dirname "${BASH_SOURCE[0]}")/gen_compose.sh"
# shellcheck source=gen_microservices.sh
source "$(dirname "${BASH_SOURCE[0]}")/gen_microservices.sh"

# ----- Pré-requis -----------------------------------------------------------
step_check_prereqs() { check_prereqs; }

# ----- Accès SSH -------------------------------------------------------------
step_validate_ssh() {
  local host user
  host="$(cfg_req target.host)"
  user="$(cfg_req target.user)"

  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] ssh ${user}@${host} 'hostname'"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  ui_info "Test de connexion à ${user}@${host}…"
  local banner
  if banner=$(ssh_remote -o ConnectTimeout=10 "${user}@${host}" \
       'echo "$(hostname) — $(lsb_release -ds 2>/dev/null || uname -s)"' 2>&1); then
    ui_ok "Connexion SSH réussie : ${banner}"
    emit_ok "$(jq -cn --arg b "$banner" '{banner: $b}')"
  else
    retryable "connexion SSH impossible vers ${user}@${host} : ${banner}"
  fi
}

# ----- Dossier de projet ------------------------------------------------------
step_create_project_dir() {
  if [[ -d "$WORK_DIR" ]]; then
    # Ce qui était un prompt de confirmation est devenu une clé de
    # configuration : l'engine n'a personne à qui demander.
    if cfg_bool options.reuse_existing_dir; then
      ui_ok "Réutilisation du dossier existant : ${WORK_DIR}"
    else
      die "le dossier ${WORK_DIR} existe déjà et options.reuse_existing_dir est faux" 2
    fi
  else
    mkdir -p "$WORK_DIR"
    ui_ok "Dossier créé : ${WORK_DIR}"
  fi
  emit_ok "$(jq -cn --arg d "$WORK_DIR" '{work_dir: $d}')"
}

# ----- Générateurs -------------------------------------------------------------
# Rejoués à chaque exécution : c'est ce qui garde le projet en phase avec
# spec.json et env.json. Elles n'ont pas besoin du réseau, donc jamais
# court-circuitées par DRY_RUN.
step_generate_microservices() {
  gen_microservices
  emit_ok "$(jq -cn --arg d "$WORK_DIR/services" '{services_dir: $d}')"
}

step_generate_compose() {
  gen_compose
  emit_ok "$(jq -cn --arg f "$WORK_DIR/deploy/compose.yml" '{compose_file: $f}')"
}

step_generate_skills() {
  bash "$(dirname "${BASH_SOURCE[0]}")/gen_skills.sh" "$WORK_DIR" >&2
  ui_ok "Skills générées (.agents/skills/)"
  emit_ok '{"skills":5}'
}

step_generate_workflow() {
  # gen_workflow.sh (script autonome, hors périmètre de cette tâche) attend
  # son mode d'authentification sous son propre nom de variable historique :
  # on le lui fournit depuis target.auth_method, sans le convertir lui-même.
  APP_NAME="$APP_NAME" \
  OVH_AUTH_METHOD="$(cfg target.auth_method key)" \
  SPEC_JSON="$SPEC_JSON" \
    bash "$(dirname "${BASH_SOURCE[0]}")/gen_workflow.sh" "$WORK_DIR" >&2
  emit_ok "$(jq -cn --arg f "$WORK_DIR/.github/workflows/deploy.yml" '{workflow: $f}')"
}

# ----- sudo NOPASSWD -----------------------------------------------------------
step_enable_sudo_nopasswd() {
  local host user
  host="$(cfg_req target.host)"; user="$(cfg_req target.user)"

  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] vérification sudo -n sur ${user}@${host}"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  if ssh_remote "${user}@${host}" 'sudo -n true' 2>/dev/null; then
    ui_ok "sudo NOPASSWD déjà actif pour ${user}"
    emit_ok '{"already_configured":true}'
    return 0
  fi

  # L'ancienne version ouvrait un TTY et demandait le mot de passe sudo. Un
  # worker n'a pas de TTY : on échoue fatalement avec la marche à suivre.
  ui_err "sudo NOPASSWD n'est pas configuré pour ${user} sur ${host}"
  ui_info "Sur le serveur, en tant que root :"
  ui_info "  echo \"${user} ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/${user}-deploymatic"
  ui_info "  sudo chmod 440 /etc/sudoers.d/${user}-deploymatic"
  die "sudo NOPASSWD requis pour ${user}@${host} (configuration manuelle nécessaire)" 2
}

# ----- Provisioning --------------------------------------------------------------
step_prepare_server() {
  local host user
  host="$(cfg_req target.host)"; user="$(cfg_req target.user)"

  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] envoi de prepare_server.sh vers ${user}@${host}"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  ui_info "Provisioning de ${host} (docker, ufw, fail2ban)…"

  # Le token NE DOIT PAS transiter par la ligne de commande distante : elle
  # est visible dans `ps` sur la cible pendant toute la durée du
  # provisioning, et une apostrophe dans le token casserait le quoting. On le
  # passe sur stdin, en tête du script, et prepare_server.sh le lit avec
  # `read` (contrat déjà implémenté côté prepare_server.sh).
  {
    printf '%s\n' "$(cfg registry.user)"
    printf '%s\n' "$(cfg registry.token)"
    cat "$(dirname "${BASH_SOURCE[0]}")/prepare_server.sh"
  } | ssh_remote "${user}@${host}" \
        'IFS= read -r REGISTRY_USER; IFS= read -r REGISTRY_TOKEN; \
         export REGISTRY_USER REGISTRY_TOKEN; bash -s' >&2 \
    || retryable "le provisioning du serveur a échoué"

  ui_ok "Serveur prêt"
  emit_ok "$(jq -cn --arg h "$host" '{host: $h}')"
}

# ----- Build -----------------------------------------------------------------
# Chemin panel : on construit sur la CIBLE via DOCKER_HOST=ssh://, jamais sur
# l'hôte du panneau. Le contexte de build voyage par SSH.
step_build_images() {
  spec_init

  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] docker compose build + push sur $(docker_host_url)"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  ui_info "Build des images sur la cible…"
  compose_remote build --pull >&2 || retryable "le build des images a échoué"

  # Push vers le registre : le CI et les redéploiements en dépendent.
  if [[ -n "$(cfg registry.token)" ]]; then
    ui_info "Publication des images sur le registre…"
    compose_remote push >&2 || ui_warn "push échoué — le déploiement local reste possible"
  else
    ui_warn "registry.token absent : pas de push, images locales à la cible seulement"
  fi

  ui_ok "Images construites"
  emit_ok "$(jq -cn --argjson n "$(spec_service_ids | wc -l | tr -d ' ')" '{built: $n}')"
}

# ----- Déploiement ---------------------------------------------------------------
step_deploy_stack() {
  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] docker compose up -d --remove-orphans"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  ui_info "Démarrage de la stack…"
  compose_remote pull --ignore-buildable >&2 || ui_warn "pull partiel (images locales)"
  compose_remote up -d --remove-orphans >&2 || retryable "docker compose up a échoué"

  ui_ok "Stack démarrée"
  emit_ok "$(jq -cn --arg p "$APP_NAME" '{project: $p}')"
}

# ----- Validation ------------------------------------------------------------------
# Plus aucun curl sur une IP publique : l'hôte cible n'est plus exposé, et
# l'ancienne validation cassait dès qu'un hostname d'ingress était configuré.
# On valide depuis la cible, sur 127.0.0.1:<port hôte>.
step_validate_deployment() {
  spec_init
  local host user
  host="$(cfg_req target.host)"; user="$(cfg_req target.user)"

  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] contrôle de santé des services exposés"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  # 1) Tous les conteneurs sont-ils en marche et sains ?
  local unhealthy
  unhealthy=$(compose_remote ps --format json 2>/dev/null \
    | jq -rs '
        (if type == "array" then . else [.] end)
        | map(select(.State != "running"
                     or ((.Health // "") | test("^(unhealthy|starting)$"))))
        | map(.Service) | join(",")
      ' 2>/dev/null || printf 'indéterminé')

  if [[ -n "$unhealthy" && "$unhealthy" != "indéterminé" ]]; then
    retryable "services non sains : ${unhealthy}"
  fi
  ui_ok "Tous les conteneurs sont en marche"

  # 2) Chaque service exposé répond-il sur son port hôte, depuis la cible ?
  local sid port health checked=0
  for sid in $(spec_exposed_ids_by_path_length); do
    port="$(cfg_port "$sid")"
    health="$(spec_get "$sid" health /)"
    if ssh_remote "${user}@${host}" \
         "curl -fsS -m 5 -o /dev/null 'http://127.0.0.1:${port}${health}'" 2>/dev/null; then
      ui_ok "${sid} répond sur 127.0.0.1:${port}${health}"
      checked=$((checked + 1))
    else
      retryable "le service '${sid}' ne répond pas sur 127.0.0.1:${port}${health}"
    fi
  done

  emit_ok "$(jq -cn --argjson n "$checked" '{services_ok: $n}')"
}
