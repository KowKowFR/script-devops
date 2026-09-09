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
# Port : target.port (optionnel, défaut 22) — une cible qui n'expose pas le
# 22 (ex. VM locale type Lima, bind sur un port non privilégié) n'a sinon
# aucun moyen d'être jointe sans passer par un ~/.ssh/config bricolé à la
# main. `ssh`/`ssh -t` attendent `-p` (minuscule), `scp` attend `-P`
# (majuscule) : piège classique, vérifié explicitement dans chaque fonction
# ci-dessous plutôt que factorisé dans un flag partagé.
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

# _target_port — port SSH de la cible, tel que déclaré dans env.json
# (target.port), 22 par défaut.
_target_port() {
  cfg target.port 22
}

ssh_remote() {
  local port; port="$(_target_port)"
  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    # Affectation séparée de l'usage (pas de "VAR=\"\$(cfg ...)\" cmd") : par
    # cohérence avec le correctif du bloc GitHub (steps.sh) même si `cfg` ne
    # meurt jamais — elle renvoie juste vide si target.password est absent.
    local pass; pass="$(cfg target.password)"
    SSHPASS="$pass" sshpass -e ssh -p "$port" "${_ssh_password_opts[@]}" "$@"
  else
    ssh -i "$(cfg_req target.ssh_key_path)" \
        -p "$port" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$@"
  fi
}

ssh_remote_tty() {
  # Identique à ssh_remote, mais alloue un TTY.
  local port; port="$(_target_port)"
  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    local pass; pass="$(cfg target.password)"
    SSHPASS="$pass" sshpass -e ssh -t -p "$port" "${_ssh_password_opts[@]}" "$@"
  else
    ssh -t -i "$(cfg_req target.ssh_key_path)" \
        -p "$port" \
        -o StrictHostKeyChecking=accept-new \
        "$@"
  fi
}

scp_remote() {
  local port; port="$(_target_port)"
  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    local pass; pass="$(cfg target.password)"
    SSHPASS="$pass" sshpass -e scp -P "$port" "${_ssh_password_opts[@]}" "$@"
  else
    scp -i "$(cfg_req target.ssh_key_path)" \
        -P "$port" \
        -o StrictHostKeyChecking=accept-new \
        "$@"
  fi
}

# ----- Pilotage Docker à distance -------------------------------------------
# Le worker ne monte JAMAIS /var/run/docker.sock. Il pilote le démon distant
# par DOCKER_HOST=ssh://, y compris pour l'hôte local, qui est une cible comme
# une autre. Un seul chemin de code, aucune exception.
#
# DÉFAUT D'ARCHITECTURE CORRIGÉ ICI (trouvé en conditions réelles contre une
# VM Lima) : Docker, face à DOCKER_HOST=ssh://…, invoque en interne le
# binaire `ssh` du PATH pour dialoguer avec le démon distant — mesuré :
# `ssh -l <user> -p <port> -o ConnectTimeout=30 -T -- <host> "docker system
# dial-stdio"`. Il n'existe AUCUNE option Docker pour lui faire porter une
# identité : ni -i, ni équivalent. `ssh_remote()` ci-dessus n'est pour rien
# dans cet appel — Docker construit et lance `ssh` tout seul. Sans
# intervention, `ssh` retombe sur les identités par défaut de l'utilisateur
# (~/.ssh/id_*) puis sur ~/.ssh/config : ça peut sembler marcher sur le poste
# d'un développeur qui a un alias qui traîne, et échouer partout ailleurs
# (CI, conteneur worker du jalon 2, machine propre) avec un « Permission
# denied (publickey) » tardif — après que validate_ssh (qui passe, lui, par
# ssh_remote() et reçoit -i explicitement) ait donné une fausse assurance.
#
# La correction : `_docker_ssh_wrapper_bin_dir` (plus bas) pose un wrapper
# `ssh` prioritaire dans le PATH, le temps d'un seul appel docker_remote,
# qui injecte l'identité (mode clé) ou route par sshpass (mode mot de
# passe) — exactement le mécanisme déjà employé et validé par le workflow CI
# généré en mode mot de passe (gen_workflow.sh, bloc « Setup SSH (password
# mode) »), étendu ici au mode clé et borné à la durée d'un seul appel
# plutôt que persistant sur tout un job.

docker_host_url() {
  printf 'ssh://%s@%s:%s' "$(cfg_req target.user)" "$(cfg_req target.host)" "$(_target_port)"
}

# _docker_ssh_wrapper_bin_dir — crée un répertoire temporaire contenant un
# wrapper `ssh` adapté au mode d'authentification de la cible
# (target.auth_method), et imprime son chemin sur stdout. L'appelant doit le
# placer en tête de PATH pour la durée de l'appel Docker, puis le supprimer
# (rm -rf) une fois terminé — rien ne doit en survivre.
#
# PIÈGE PRINCIPAL : le VRAI binaire ssh doit être résolu ICI, PENDANT que
# PATH est encore intact — avant que l'appelant ne place ce répertoire en
# tête de PATH. Sinon le wrapper s'invoquerait lui-même en boucle infinie dès
# le premier appel de Docker. `command -v ssh` est donc la toute première
# ligne de cette fonction, et son résultat (chemin absolu) est écrit en dur
# dans le script généré — jamais résolu de nouveau à l'intérieur du wrapper.
#
# Port : PAS ajouté ici. Mesuré (docker version, DOCKER_HOST=ssh://…:60122,
# faux ssh journalisant ses arguments) : Docker le transmet déjà lui-même en
# `-p <port>`, lu depuis l'URL ssh://…, avant que le wrapper ne voie quoi que
# ce soit. Un port ajouté ici en ferait doublon (deux `-p`, comportement
# ssh non spécifié en cas de conflit) pour ne corriger aucune panne réelle.
#
# StrictHostKeyChecking=accept-new : identique à ssh_remote/ssh_remote_tty/
# scp_remote ci-dessus — un seul comportement de vérification d'hôte, qu'on
# passe par SSH direct ou par DOCKER_HOST.
_docker_ssh_wrapper_bin_dir() {
  local dir real_ssh
  real_ssh="$(command -v ssh)" || die "binaire ssh introuvable dans PATH" 2
  dir="$(mktemp -d)" || die "impossible de créer le répertoire temporaire du wrapper ssh" 2

  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    # Le mot de passe NE PASSE PAS par ce fichier : sshpass -e le lit depuis
    # la variable d'environnement SSHPASS, positionnée par docker_remote au
    # moment de l'appel — jamais sur une ligne de commande, jamais visible
    # dans `ps`. Mêmes options que _ssh_password_opts (cohérence avec
    # ssh_remote) et que le wrapper généré côté CI (gen_workflow.sh).
    cat > "$dir/ssh" <<EOF
#!/usr/bin/env bash
exec sshpass -e "$real_ssh" \\
  -o StrictHostKeyChecking=accept-new \\
  -o PreferredAuthentications=password \\
  -o PubkeyAuthentication=no \\
  "\$@"
EOF
  else
    local key; key="$(cfg_req target.ssh_key_path)"
    cat > "$dir/ssh" <<EOF
#!/usr/bin/env bash
exec "$real_ssh" \\
  -i "$key" \\
  -o BatchMode=yes \\
  -o StrictHostKeyChecking=accept-new \\
  "\$@"
EOF
  fi
  chmod +x "$dir/ssh"
  printf '%s' "$dir"
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
#
# `|| rc=$?` (et non `docker ...; rc=$?`) : sous `set -e` (bootstrap.sh),
# laisser échouer directement la commande de premier plan sortirait du
# script AVANT le `rm -rf` qui suit — le wrapper resterait sur disque. Cette
# forme neutralise l'échec pour `set -e` (le `||` réussit toujours) tout en
# conservant le code de sortie réel dans `rc`, nettoyé dans tous les cas.
docker_remote() {
  if (( ${DRY_RUN:-0} == 1 )) && _docker_mutating_action "${1:-}"; then
    ui_info "[dry-run] DOCKER_HOST=$(docker_host_url) docker $*"
    return 0
  fi

  local wrapper_dir rc pass
  wrapper_dir="$(_docker_ssh_wrapper_bin_dir)"
  pass="$(cfg target.password)"
  rc=0
  PATH="${wrapper_dir}:${PATH}" \
    SSHPASS="$pass" \
    DOCKER_HOST="$(docker_host_url)" \
    docker "$@" || rc=$?
  rm -rf "$wrapper_dir"
  return "$rc"
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
