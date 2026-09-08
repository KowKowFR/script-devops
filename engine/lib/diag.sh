#!/usr/bin/env bash
# engine/lib/diag.sh — diagnostic d'une application déployée.
#
# Ces commandes sont appelées à la main pendant le développement de l'engine ;
# le panel les remplacera par des vues (jalon 2). Elles écrivent sur stderr et
# ne respectent pas le contrat JSON — ce ne sont pas des étapes.

cmd_doctor() {
  local fails=0 host user
  host="$(cfg_req target.host)"; user="$(cfg_req target.user)"

  ui_step "Doctor — ${APP_NAME} sur ${host}"

  ui_info "Outils locaux :"
  local tool
  for tool in git ssh curl jq docker; do
    if command -v "$tool" >/dev/null 2>&1; then ui_ok "$tool"
    else ui_err "$tool absent"; fails=$((fails + 1)); fi
  done

  ui_info "Accès à la cible :"
  if ssh_remote -o ConnectTimeout=5 "${user}@${host}" true 2>/dev/null; then
    ui_ok "SSH"
    if docker_remote version >/dev/null 2>&1; then ui_ok "démon Docker joignable"
    else ui_err "démon Docker injoignable via DOCKER_HOST"; fails=$((fails + 1)); fi
  else
    ui_err "SSH inaccessible"; fails=$((fails + 1))
  fi

  ui_info "Fichier compose :"
  if compose_remote config --quiet 2>/dev/null; then ui_ok "compose.yml valide"
  else ui_err "compose.yml invalide"; fails=$((fails + 1)); fi

  ui_info "Conteneurs :"
  compose_remote ps >&2 || fails=$((fails + 1))

  ui_info "Endpoints (depuis la cible) :"
  local sid port health
  for sid in $(spec_exposed_ids_by_path_length 2>/dev/null); do
    port="$(cfg_port "$sid")"; health="$(spec_get "$sid" health /)"
    if ssh_remote "${user}@${host}" \
         "curl -fsS -m 5 -o /dev/null 'http://127.0.0.1:${port}${health}'" 2>/dev/null; then
      ui_ok "${sid} → 127.0.0.1:${port}${health}"
    else
      ui_err "${sid} → 127.0.0.1:${port}${health}"; fails=$((fails + 1))
    fi
  done

  if (( fails == 0 )); then ui_ok "Tous les contrôles passent"; return 0; fi
  ui_err "${fails} contrôle(s) en échec"
  return 1
}

cmd_logs() {
  local service="${1:-}"
  if [[ -z "$service" ]]; then
    compose_remote logs -f --tail=200 >&2
  else
    compose_remote logs -f --tail=200 "$service" >&2
  fi
}

cmd_stack_info() {
  ui_step "État de la stack ${APP_NAME}"
  compose_remote ps >&2
  echo >&2
  compose_remote images >&2
  echo >&2
  docker_remote system df >&2
}

# Alias déprécié — l'ancien nom parlait de cluster Kubernetes.
cmd_cluster_info() {
  ui_warn "cmd_cluster_info est déprécié : utiliser cmd_stack_info (il n'y a plus de cluster)"
  cmd_stack_info
}
