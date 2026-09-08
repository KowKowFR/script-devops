#!/usr/bin/env bash
# lib/ssh_remote.sh — Wrappers SSH/SCP unifiés (clé OU mot de passe) et
# pilotage Docker à distance.
#
# La méthode est choisie via env.json : target.auth_method (key|password) :
#   - "password" : passe par sshpass, désactive BatchMode et PubkeyAuth ;
#     lit target.password
#   - "key"      : utilise target.ssh_key_path avec BatchMode=yes
#
# Ces trois valeurs viennent de cfg/cfg_req (lib/config.sh). Depuis le passage
# à env.json, les anciennes variables d'environnement de l'ère Kubernetes
# (auth method / chemin de clé / mot de passe, lues en dur dans le shell)
# n'existent plus nulle part ailleurs dans l'engine — les relire ici serait
# une panne SILENCIEUSE : repli sur le mode clé avec un chemin de clé vide,
# `ssh -i ''` échouant loin de la cause réelle.
#
# Trois entrées (toutes prennent les mêmes args que ssh/scp) :
#   ssh_remote      [args...] user@host "cmd"   — usage standard non-interactif
#   ssh_remote_tty  [args...] user@host         — TTY alloué (heredoc avec input)
#   scp_remote      [args...] src... user@host:dst
#
# Dépend de : cfg, cfg_req (lib/config.sh).

_ssh_password_opts=(
  -o StrictHostKeyChecking=accept-new
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
)

ssh_remote() {
  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    SSHPASS="$(cfg target.password)" sshpass -e ssh "${_ssh_password_opts[@]}" "$@"
  else
    ssh -i "$(cfg_req target.ssh_key_path)" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$@"
  fi
}

ssh_remote_tty() {
  # Identique à ssh_remote, mais alloue un TTY.
  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    SSHPASS="$(cfg target.password)" sshpass -e ssh -t "${_ssh_password_opts[@]}" "$@"
  else
    ssh -t -i "$(cfg_req target.ssh_key_path)" \
        -o StrictHostKeyChecking=accept-new \
        "$@"
  fi
}

scp_remote() {
  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    SSHPASS="$(cfg target.password)" sshpass -e scp "${_ssh_password_opts[@]}" "$@"
  else
    scp -i "$(cfg_req target.ssh_key_path)" \
        -o StrictHostKeyChecking=accept-new \
        "$@"
  fi
}

# ----- Pilotage Docker à distance -------------------------------------------
# Le worker ne monte JAMAIS /var/run/docker.sock. Il pilote le démon distant
# par DOCKER_HOST=ssh://, y compris pour l'hôte local, qui est une cible comme
# une autre. Un seul chemin de code, aucune exception.

docker_host_url() {
  printf 'ssh://%s@%s' "$(cfg_req target.user)" "$(cfg_req target.host)"
}

# _docker_mutating_action ACTION — code 0 si ACTION modifie l'état de la
# cible (construit, publie, démarre/arrête des conteneurs), 1 sinon.
#
# Pourquoi ce n'est pas un simple `(( DRY_RUN == 1 ))` inconditionnel dans
# docker_remote (Task 11, point 3 du brief de dispatch) : lib/diag.sh
# (cmd_doctor) appelle `docker_remote version` et `compose_remote config
# --quiet` pour vérifier que le démon répond et que le fichier est valide. Un
# court-circuit inconditionnel rendrait ces deux appels TOUJOURS "réussis"
# sous DRY_RUN=1 sans avoir rien vérifié — cmd_doctor annoncerait "démon
# Docker joignable" / "compose.yml valide" alors qu'aucune commande n'a
# tourné : un faux positif dans l'outil censé détecter les pannes.
#
# Le court-circuit ne s'applique donc qu'aux actions qui MODIFIENT l'état de
# la cible ; tout le reste (version, compose config/ps/images/logs, system
# df…) s'exécute pour de vrai même sous DRY_RUN=1. En pratique, les step_*
# qui appellent docker_remote/compose_remote (build_images, deploy_stack)
# court-circuitent déjà AVANT d'atteindre cette fonction (elles testent
# DRY_RUN en tête et rendent la main sans rien appeler) : cette liste sert
# surtout de filet pour tout appelant direct — diag.sh aujourd'hui, d'autres
# demain — qui n'aurait pas ce garde-fou.
_docker_mutating_action() {
  case "${1:-}" in
    build|push|pull|up|down|restart|stop|start|kill|rm|exec|run|create| \
    rename|cp|prune|network|volume|pause|unpause|wait|attach|login|logout)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# docker_remote ARGS… — exécute une commande docker sur la cible.
docker_remote() {
  if (( ${DRY_RUN:-0} == 1 )) && _docker_mutating_action "${1:-}"; then
    ui_info "[dry-run] DOCKER_HOST=$(docker_host_url) docker $*"
    return 0
  fi
  DOCKER_HOST="$(docker_host_url)" docker "$@"
}

# compose_remote ARGS… — docker compose sur la cible, dans deploy/.
#
# Le premier argument (build, up, pull… ou config, ps, images, logs…) décide
# seul si l'appel est court-circuité en dry-run : docker_remote ne voit que
# "compose" en $1 et ne peut pas trancher à sa place (cf. commentaire de
# _docker_mutating_action ci-dessus).
compose_remote() {
  if (( ${DRY_RUN:-0} == 1 )) && _docker_mutating_action "${1:-}"; then
    ui_info "[dry-run] DOCKER_HOST=$(docker_host_url) docker compose --project-name ${APP_NAME:-} $*"
    return 0
  fi
  docker_remote compose \
    --project-name "$APP_NAME" \
    --file "${WORK_DIR}/deploy/compose.yml" \
    --env-file "${WORK_DIR}/deploy/.env" \
    "$@"
}
