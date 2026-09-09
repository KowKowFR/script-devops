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

# gen_compose.sh expose aussi `_capture` (VARNAME CMD... — équivalent de
# VARNAME="$(CMD...)" qui reste correct quand CMD peut appeler `die`) : le
# bloc GitHub plus bas la réutilise telle quelle plutôt que de dupliquer le
# correctif — voir son commentaire dans gen_compose.sh pour le pourquoi.

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
  # gen_workflow.sh attend son mode d'authentification sous TARGET_AUTH_METHOD
  # (renommé depuis OVH_AUTH_METHOD — le vestige Kubernetes a disparu des deux
  # côtés en même temps, pour ne jamais retomber silencieusement sur le mode
  # "key" par défaut). SPEC_JSON/ENV_JSON lui servent à construire le contrôle
  # de santé (un curl par service exposé, sur son port hôte).
  APP_NAME="$APP_NAME" \
  TARGET_AUTH_METHOD="$(cfg target.auth_method key)" \
  SPEC_JSON="$SPEC_JSON" \
  ENV_JSON="$ENV_JSON" \
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

# ----- Bloc GitHub (optionnel) ----------------------------------------------
# Décision d'architecture : GitHub est un extra, pas le chemin de déploiement.
# Le panel déploie lui-même (build_images + deploy_stack). Une panne GitHub ne
# doit jamais empêcher une application de tourner — d'où la position de ce bloc
# en fin de séquence, et le court-circuit ci-dessous.

_github_skip_if_disabled() {
  if ! cfg_bool github.enabled; then
    ui_skip "bloc GitHub désactivé (github.enabled=false)"
    emit_ok '{"skipped":true}'
    return 0
  fi
  return 1
}

_gh() {
  # gh s'authentifie par GH_TOKEN, jamais par `gh auth login` (interactif).
  #
  # BUG CORRIGÉ (revue) : `GH_TOKEN="$(cfg_req github.token)" gh "$@"`
  # semblait sûr, ne l'était pas. En bash, une substitution de commande
  # utilisée en PRÉFIXE d'affectation temporaire d'une autre commande fork un
  # sous-shell pour cfg_req — son die() y appelle bien `exit 2`, mais ça ne
  # quitte QUE ce sous-shell. Le code de sortie de la substitution n'est même
  # plus regardé (seul celui de `gh` compte pour `set -e`) : `gh` s'exécute
  # quand même, avec le JSON d'erreur de die() comme valeur de GH_TOKEN — un
  # vrai appel réseau vers l'API GitHub avec un jeton corrompu au lieu d'un
  # jeton absent. Reproduit en revue : `HTTP 401: Bad credentials`.
  #
  # `_capture` (définie dans gen_compose.sh, sourcé en tête de ce fichier)
  # évite exactement ce piège : elle relaie le message de die() sur le VRAI
  # stdout et sort avec le bon code AVANT que `gh` ne soit jamais invoqué.
  local token; _capture token cfg_req github.token
  GH_TOKEN="$token" gh "$@"
}

step_github_create_repo() {
  _github_skip_if_disabled && return 0
  local gh_user gh_repo
  _capture gh_user cfg_req github.user
  _capture gh_repo cfg_req github.repo
  # github.token validé ICI, avant tout appel à _gh : plus bas, le premier
  # appel (`_gh repo view ... >/dev/null 2>&1`) redirige stdout ET stderr
  # vers /dev/null pour sonder discrètement l'existence du dépôt — un die()
  # qui se déclencherait DANS cet appel (le contrôle interne de _gh sur
  # github.token) verrait son JSON d'erreur avalé par cette redirection,
  # PAS par un sous-shell cette fois, mais avec le même résultat : rien sur
  # le vrai stdout, alors que _capture aurait déjà positionné
  # _RESULT_EMITTED=1 — l'appelant ne verrait jamais aucune ligne JSON. En
  # validant ici, hors de toute redirection, le die() (s'il a lieu) part
  # bien sur le vrai stdout avant que _gh ne soit jamais invoqué.
  local gh_token; _capture gh_token cfg_req github.token
  local repo="${gh_user}/${gh_repo}"

  if _gh repo view "$repo" >/dev/null 2>&1; then
    if cfg_bool options.allow_existing_repo; then
      ui_ok "Dépôt existant réutilisé : ${repo}"
      emit_ok "$(jq -cn --arg r "$repo" '{repo: $r, created: false}')"
      return 0
    fi
    die "le dépôt ${repo} existe déjà et options.allow_existing_repo est faux" 2
  fi

  _gh repo create "$repo" --public \
    --description "Déployé par DeployMatic" >&2 \
    || retryable "création du dépôt ${repo} impossible"
  ui_ok "Dépôt créé : https://github.com/${repo}"
  emit_ok "$(jq -cn --arg r "$repo" '{repo: $r, created: true}')"
}

step_github_set_secrets() {
  _github_skip_if_disabled && return 0
  local gh_user gh_repo
  _capture gh_user cfg_req github.user
  _capture gh_repo cfg_req github.repo
  # github.token validé ICI (voir le commentaire équivalent dans
  # step_github_create_repo) : tous les appels _gh plus bas redirigent leur
  # stdout vers stderr (`>&2`), ce qui avalerait le JSON de die() si le
  # contrôle interne de _gh se déclenchait pour la toute première fois à
  # l'intérieur d'un de ces appels redirigés.
  local gh_token; _capture gh_token cfg_req github.token
  local repo="${gh_user}/${gh_repo}"

  # Même piège que _gh ci-dessus pour CHAQUE valeur de secret : un
  # `--body "$(cfg_req ...)"` swallow-erait un die() en secret corrompu
  # (le JSON d'erreur posé tel quel comme valeur du secret GitHub), au lieu
  # de faire échouer la génération avant tout appel réseau. `_capture`
  # partout où une valeur requise nourrit un argument de commande.
  local reg_user reg_token t_host t_user
  _capture reg_user  cfg_req registry.user
  _capture reg_token cfg_req registry.token
  _capture t_host    cfg_req target.host
  _capture t_user    cfg_req target.user

  local n=0
  _gh secret set DOCKERHUB_USERNAME --repo "$repo" --body "$reg_user"  >&2 && n=$((n+1))
  _gh secret set DOCKERHUB_TOKEN    --repo "$repo" --body "$reg_token" >&2 && n=$((n+1))
  _gh secret set TARGET_HOST        --repo "$repo" --body "$t_host"    >&2 && n=$((n+1))
  _gh secret set TARGET_USER        --repo "$repo" --body "$t_user"    >&2 && n=$((n+1))

  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    local t_pass; _capture t_pass cfg_req target.password
    _gh secret set TARGET_PASSWORD --repo "$repo" --body "$t_pass" >&2 && n=$((n+1))
  else
    local key_path; _capture key_path cfg_req target.ssh_key_path
    ssh-keygen -y -f "$key_path" >/dev/null 2>&1 \
      || die "clé SSH invalide ou protégée par passphrase : ${key_path} (le runner CI ne peut pas la déverrouiller)" 2
    # Une clé sans saut de ligne final provoque "error in libcrypto" côté runner.
    local tmp; tmp=$(mktemp)
    cat "$key_path" > "$tmp"
    [[ -z "$(tail -c1 "$tmp")" ]] || printf '\n' >> "$tmp"
    _gh secret set TARGET_SSH_KEY --repo "$repo" < "$tmp" >&2 && n=$((n+1))
    rm -f "$tmp"
  fi

  ui_ok "${n} secrets configurés"
  emit_ok "$(jq -cn --argjson n "$n" '{secrets: $n}')"
}

step_git_init() {
  _github_skip_if_disabled && return 0
  local gh_user gh_repo
  _capture gh_user cfg_req github.user
  _capture gh_repo cfg_req github.repo
  local url="https://github.com/${gh_user}/${gh_repo}.git"
  (
    cd "$WORK_DIR" || exit 1
    [[ -d .git ]] || git init -q -b main
    cat > .gitignore <<'GITIGNORE'
node_modules/
npm-debug.log
*.log
.DS_Store
.vscode/
.idea/
deploy/.env
GITIGNORE
    git remote add origin "$url" 2>/dev/null || git remote set-url origin "$url"
  ) >&2 || retryable "initialisation git impossible dans ${WORK_DIR}"

  ui_ok "Dépôt local initialisé, origin → ${url}"
  emit_ok "$(jq -cn --arg u "$url" '{remote: $u}')"
}

step_git_push() {
  _github_skip_if_disabled && return 0
  # user et token récupérés AVANT le sous-shell : à l'intérieur, un die() de
  # cfg_req serait de toute façon avalé par le `|| retryable` qui l'entoure
  # (code 1 générique "push impossible" au lieu du fatal nommant le
  # paramètre manquant) — les valider ici garantit aussi qu'aucune commande
  # git (donc aucun appel réseau) ne s'exécute avant que github.user/token
  # ne soient confirmés présents.
  local user token
  _capture user cfg_req github.user
  _capture token cfg_req github.token
  (
    cd "$WORK_DIR" || exit 1
    git add .
    if git diff --cached --quiet; then
      echo "aucun changement à commiter" >&2
    else
      git -c user.email="${user}@users.noreply.github.com" -c user.name="$user" \
          commit -q -m "chore: déploiement initial par DeployMatic"
    fi
    GH_TOKEN="$token" git push -u origin main
  ) >&2 || retryable "push vers origin/main impossible"

  ui_ok "Push réussi"
  local repo; _capture repo cfg_req github.repo
  emit_ok "$(jq -cn --arg u "https://github.com/${user}/${repo}" '{repo_url: $u}')"
}
